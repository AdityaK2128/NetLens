import Foundation
import MapKit
import AppKit
import Observation

/// Equirectangular land/water mask used to place the globe's dots.
///
/// It is generated on this Mac the first time the globe is shown — by rendering Apple
/// Maps snapshots and classifying water (blue-dominant) versus land — and cached in
/// Application Support. Nothing derived from map data ships with the app.
@MainActor
enum LandMask {
    nonisolated static let width = 1440
    nonisolated static let height = 720

    @Observable
    final class Status {
        var generating = false
        var progress = 0.0
    }
    static let status = Status()

    private static var task: Task<[UInt8]?, Never>?

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("landmask-v1.png")
    }

    /// The cached mask, or a freshly generated one (takes ~20–40 s, once).
    static func obtain() async -> [UInt8]? {
        if let cached = loadCached() { return cached }
        if let task { return await task.value }
        let t = Task { await generate() }
        task = t
        let result = await t.value
        task = nil
        return result
    }

    private static func loadCached() -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(cacheURL as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == width, img.height == height else { return nil }
        var px = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))   // row 0 = north
        return px
    }

    // MARK: generation

    private struct Tile: @unchecked Sendable {
        let snapshot: MKMapSnapshotter.Snapshot
        let region: MKCoordinateRegion
        let rgba: [UInt8]
        let w: Int
        let h: Int
    }

    private static func regions() -> [MKCoordinateRegion] {
        // (north, south, longitude step) — narrower tiles where Mercator stretches most.
        let bands: [(Double, Double, Double)] = [(85, 72, 60), (72, 56, 30), (58, 30, 30), (30, 0, 30),
                                                 (0, -30, 30), (-30, -58, 30), (-56, -72, 30), (-72, -85, 60)]
        var out: [MKCoordinateRegion] = []
        for (n, s, step) in bands {
            var lon = -180.0
            while lon < 180 {
                out.append(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (n + s) / 2, longitude: lon + step / 2),
                                              span: MKCoordinateSpan(latitudeDelta: (n - s) * 1.06, longitudeDelta: step * 1.06)))
                lon += step
            }
        }
        return out
    }

    private static func generate() async -> [UInt8]? {
        status.generating = true
        status.progress = 0
        defer { status.generating = false }

        let specs = regions()
        var tiles: [Tile] = []
        for (i, region) in specs.enumerated() {
            let o = MKMapSnapshotter.Options()
            o.region = region
            o.size = NSSize(width: 640, height: 640)
            let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            cfg.pointOfInterestFilter = .excludingAll
            cfg.showsTraffic = false
            o.preferredConfiguration = cfg
            o.appearance = NSAppearance(named: .aqua)
            if let snap = try? await MKMapSnapshotter(options: o).start() {
                tiles.append(render(snap, region: region))
            }
            status.progress = Double(i + 1) / Double(specs.count)
        }
        guard tiles.count > specs.count / 2 else { return nil }   // offline or blocked

        let mask = await Task.detached(priority: .userInitiated) { classify(tiles) }.value
        save(mask)
        return mask
    }

    private static func render(_ s: MKMapSnapshotter.Snapshot, region: MKCoordinateRegion) -> Tile {
        let size = s.image.size
        let w = Int(size.width), h = Int(size.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        var rect = CGRect(origin: .zero, size: size)
        if let cg = s.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
           let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Tile(snapshot: s, region: region, rgba: buf, w: w, h: h)
    }

    nonisolated private static func classify(_ tiles: [Tile]) -> [UInt8] {
        let W = width, H = height
        var mask = [UInt8](repeating: 0, count: W * H)
        for j in 0..<H {
            let lat = 90.0 - (Double(j) + 0.5) * 180.0 / Double(H)
            for i in 0..<W {
                if lat < -84 { mask[j * W + i] = 255; continue }   // Antarctic interior
                if lat > 84 { continue }                             // Arctic ocean
                let lon = -180.0 + (Double(i) + 0.5) * 360.0 / Double(W)
                let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                for t in tiles {
                    // cheap bounds check before asking the snapshot to project
                    guard abs(lat - t.region.center.latitude) <= t.region.span.latitudeDelta / 2,
                          abs(lon - t.region.center.longitude) <= t.region.span.longitudeDelta / 2 else { continue }
                    let p = t.snapshot.point(for: c)
                    let x = Int(p.x), y = Int(p.y)
                    guard x >= 2, y >= 2, x < t.w - 2, y < t.h - 2 else { continue }
                    var land = 0
                    for dy in -1...1 { for dx in -1...1 {
                        // Water renders blue-dominant; land is beige / green / white.
                        // snapshot point() is top-left origin; the bitmap's rows run bottom-up
                        let k = ((t.h - 1 - (y + dy)) * t.w + (x + dx)) * 4
                        let r = Int(t.rgba[k]), g = Int(t.rgba[k + 1]), b = Int(t.rgba[k + 2])
                        if !(b - r > 22 && b > g - 4) { land += 1 }
                    }}
                    if land >= 5 { mask[j * W + i] = 255 }
                    break
                }
            }
        }
        // Close thin rivers/lakes, then remove isolated specks (labels, graticule lines).
        func neighbours(_ m: [UInt8], _ i: Int, _ j: Int) -> Int {
            var n = 0
            for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                let jj = j + dj
                guard jj >= 0, jj < H else { continue }
                if m[jj * W + (i + di + W) % W] != 0 { n += 1 }
            }}
            return n
        }
        for _ in 0..<2 {
            var m2 = mask
            for j in 0..<H { for i in 0..<W where mask[j * W + i] == 0 && neighbours(mask, i, j) >= 5 { m2[j * W + i] = 255 } }
            mask = m2
        }
        for _ in 0..<2 {
            var m2 = mask
            for j in 0..<H { for i in 0..<W where mask[j * W + i] != 0 && neighbours(mask, i, j) <= 2 { m2[j * W + i] = 0 } }
            mask = m2
        }
        return mask
    }

    private static func save(_ mask: [UInt8]) {
        var m = mask
        guard let ctx = CGContext(data: &m, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(cacheURL as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
