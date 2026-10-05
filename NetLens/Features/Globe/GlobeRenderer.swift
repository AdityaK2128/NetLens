import Foundation
import MetalKit
import simd
import AppKit

// MARK: - GPU structs (mirror GlobeShaders.metal)

struct GlobeUniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var cameraPos: SIMD4<Float>
    var viewport: SIMD2<Float>
    var time: Float
    var pointScale: Float
    var globeCenterPx: SIMD2<Float>
    var globeRadiusPx: Float
    var zoom: Float
    var sunDir: SIMD4<Float>
    var bgColor: SIMD4<Float>
    var oceanColor: SIMD4<Float>
    var landColor: SIMD4<Float>
    var lineColor: SIMD4<Float>
    var flags: SIMD4<Float>
}

/// Colours for the current appearance, resolved from system colours.
struct GlobePalette {
    var bg: SIMD4<Float>
    var ocean: SIMD4<Float>
    var land: SIMD4<Float>
    var line: SIMD4<Float>
    var dark: Bool

    @MainActor
    static func current(for appearance: NSAppearance) -> GlobePalette {
        var p = GlobePalette(bg: .zero, ocean: .zero, land: .zero, line: .zero, dark: false)
        appearance.performAsCurrentDrawingAppearance {
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .gray
            let b = SIMD4<Float>(Float(bg.redComponent), Float(bg.greenComponent), Float(bg.blueComponent), 1)
            p.dark = dark
            p.bg = b
            if dark {
                p.ocean = SIMD4(b.x + 0.045, b.y + 0.045, b.z + 0.05, 1)
                p.land = SIMD4(0.92, 0.92, 0.94, 0.62)
                p.line = SIMD4(1, 1, 1, 0.06)
            } else {
                p.ocean = SIMD4(1, 1, 1, 1)
                p.land = SIMD4(0.38, 0.40, 0.44, 0.62)
                p.line = SIMD4(0, 0, 0, 0.07)
            }
        }
        return p
    }
}

struct ArcVertexGPU {
    var pos: SIMD3<Float>
    var next: SIMD3<Float>
    var t: Float
    var side: Float
    var arc: UInt32
    var pad: Float = 0
}

struct ArcDataGPU {
    var color: SIMD4<Float>
    var width: Float
    var downRate: Float
    var upRate: Float
    var phase: Float
    var intensity: Float
    var selected: Float
    var pad: SIMD2<Float> = .zero
}

struct MarkerGPU {
    var pos: SIMD3<Float>
    var color: SIMD4<Float>
    var size: Float
    var pulse: Float
    var kind: Float
    var pad: Float = 0
}

// MARK: - Scene description (built by the SwiftUI layer)

struct GlobeArcSpec {
    let id: String
    let from: SIMD3<Float>
    let to: SIMD3<Float>
    var color: SIMD4<Float>
    var width: Float = 1.5
    var down: Float = 0
    var up: Float = 0
    var intensity: Float = 1
}

struct GlobeMarkerSpec {
    let id: String
    let pos: SIMD3<Float>
    var color: SIMD4<Float>
    var size: Float = 14
    var pulse: Float = 0
    var kind: Float = 0
    var label: String?
    var labelColor: NSColor = .white
    var labelPriority: Int = 0
}

struct GlobeSceneSpec {
    var arcs: [GlobeArcSpec] = []
    var markers: [GlobeMarkerSpec] = []
}

extension SIMD4 where Scalar == Float {
    init(_ c: NSColor, alpha: Float = 1) {
        let s = c.usingColorSpace(.sRGB) ?? c
        self.init(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), alpha)
    }
}

// MARK: - Renderer

@MainActor
final class GlobeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var atmospherePSO: MTLRenderPipelineState!
    private var spherePSO: MTLRenderPipelineState!
    private var dotsPSO: MTLRenderPipelineState!
    private var arcPSO: MTLRenderPipelineState!
    private var markerPSO: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!
    private var depthRead: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    private var sphereVB: MTLBuffer!
    private var sphereIB: MTLBuffer!
    private var sphereIndexCount = 0
    private var dotsVB: MTLBuffer?
    private var dotCount = 0
    private var arcVB: MTLBuffer?
    private var arcIB: MTLBuffer?
    private var arcIndexCount = 0
    private var arcDataBuf: MTLBuffer?
    private var markerBuf: MTLBuffer?
    private var markerCount = 0

    // Camera — yaw/pitch are the lon/lat (radians) facing the viewer.
    var yaw: Float = 0
    var pitch: Float = 0.35
    var dist: Float = 5.0
    private var targetYaw: Float?
    private var targetPitch: Float?
    private var targetDist: Float?
    private var velocity = SIMD2<Float>(0, 0)
    var autoRotate = true
    var lastInteraction = Date.distantPast
    var dragging = false

    private let startTime = CACurrentMediaTime()
    private(set) var scene = GlobeSceneSpec()
    var selectedID: String? { didSet { if oldValue != selectedID { rebuildArcData() } } }
    var hoveredID: String?

    private(set) var viewProj = matrix_identity_float4x4
    private(set) var model = matrix_identity_float4x4
    private(set) var viewSize = CGSize(width: 1, height: 1)
    var backingScale: Float = 2
    var palette = GlobePalette(bg: SIMD4(0.93, 0.93, 0.93, 1), ocean: SIMD4(1, 1, 1, 1), land: SIMD4(0.38, 0.4, 0.44, 0.62), line: SIMD4(0, 0, 0, 0.07), dark: false)
    var onFrame: (() -> Void)?

    private let fovy: Float = 30 * .pi / 180

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        view.preferredFramesPerSecond = 60
        do {
            try buildPipelines(view)
        } catch {
            NSLog("Globe pipeline error: \(error)")
            return nil
        }
        buildSphere()
        Task { [weak self] in
            guard let mask = await LandMask.obtain() else { return }
            let dots = await Task.detached(priority: .userInitiated) {
                LandDots.generate(mask: mask, width: LandMask.width, height: LandMask.height)
            }.value
            self?.uploadDots(dots)
        }
    }

    // MARK: setup

    private func buildPipelines(_ view: MTKView) throws {
        // Shaders ship as source and are compiled at launch (~50 ms) — no Metal
        // toolchain needed to build the app.
        guard let url = Bundle.main.url(forResource: "GlobeShaders", withExtension: "msl"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw NSError(domain: "Globe", code: 1) }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let lib = try device.makeLibrary(source: source, options: options)
        func pso(_ v: String, _ f: String, blend: Int) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            let ca = d.colorAttachments[0]!
            switch blend {
            case 1: // premultiplied alpha
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case 2: // additive glow
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
                ca.destinationRGBBlendFactor = .one; ca.destinationAlphaBlendFactor = .one
            default: break
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        atmospherePSO = try pso("atmosphere_vertex", "atmosphere_fragment", blend: 0)
        spherePSO = try pso("sphere_vertex", "sphere_fragment", blend: 0)
        dotsPSO = try pso("dots_vertex", "dots_fragment", blend: 1)
        arcPSO = try pso("arc_vertex", "arc_fragment", blend: 1)
        markerPSO = try pso("marker_vertex", "marker_fragment", blend: 1)

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .less
        dw.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: dw)
        let dr = MTLDepthStencilDescriptor()
        dr.depthCompareFunction = .lessEqual
        dr.isDepthWriteEnabled = false
        depthRead = device.makeDepthStencilState(descriptor: dr)
        let off = MTLDepthStencilDescriptor()
        off.depthCompareFunction = .always
        off.isDepthWriteEnabled = false
        depthOff = device.makeDepthStencilState(descriptor: off)
    }

    private func buildSphere() {
        let stacks = 64, slices = 128
        var verts: [SIMD4<Float>] = []
        var idx: [UInt32] = []
        for i in 0...stacks {
            let lat = Float.pi / 2 - Float(i) / Float(stacks) * .pi
            for j in 0...slices {
                let lon = Float(j) / Float(slices) * 2 * .pi - .pi
                verts.append(SIMD4(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon), 1))
            }
        }
        for i in 0..<stacks {
            for j in 0..<slices {
                let a = UInt32(i * (slices + 1) + j)
                let b = a + UInt32(slices + 1)
                idx += [a, b, a + 1, b, b + 1, a + 1]
            }
        }
        sphereVB = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD4<Float>>.stride)
        sphereIB = device.makeBuffer(bytes: idx, length: idx.count * 4)
        sphereIndexCount = idx.count
    }

    private func uploadDots(_ dots: [SIMD4<Float>]) {
        guard !dots.isEmpty else { return }
        dotsVB = device.makeBuffer(bytes: dots, length: dots.count * MemoryLayout<SIMD4<Float>>.stride)
        dotCount = dots.count
    }

    // MARK: scene

    func setScene(_ s: GlobeSceneSpec) {
        scene = s
        rebuildArcGeometry()
        rebuildArcData()
        rebuildMarkers()
    }

    private func rebuildArcGeometry() {
        var verts: [ArcVertexGPU] = []
        var idx: [UInt32] = []
        for (ai, arc) in scene.arcs.enumerated() {
            let pts = Self.arcPoints(arc.from, arc.to)
            guard pts.count >= 2 else { continue }
            let base = UInt32(verts.count)
            for (i, p) in pts.enumerated() {
                let next = i + 1 < pts.count ? pts[i + 1] : p + (p - pts[i - 1])
                let t = Float(i) / Float(pts.count - 1)
                verts.append(ArcVertexGPU(pos: p, next: next, t: t, side: -1, arc: UInt32(ai)))
                verts.append(ArcVertexGPU(pos: p, next: next, t: t, side: 1, arc: UInt32(ai)))
            }
            for i in 0..<(pts.count - 1) {
                let a = base + UInt32(i * 2)
                idx += [a, a + 1, a + 2, a + 1, a + 3, a + 2]
            }
        }
        if verts.isEmpty {
            arcVB = nil; arcIB = nil; arcIndexCount = 0
            return
        }
        arcVB = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<ArcVertexGPU>.stride)
        arcIB = device.makeBuffer(bytes: idx, length: idx.count * 4)
        arcIndexCount = idx.count
    }

    private func rebuildArcData() {
        guard !scene.arcs.isEmpty else { arcDataBuf = nil; return }
        let data = scene.arcs.enumerated().map { i, a in
            ArcDataGPU(color: a.color, width: a.width, downRate: a.down, upRate: a.up,
                       phase: Float(i) * 0.137, intensity: a.intensity, selected: a.id == selectedID ? 1 : 0)
        }
        arcDataBuf = device.makeBuffer(bytes: data, length: data.count * MemoryLayout<ArcDataGPU>.stride)
    }

    private func rebuildMarkers() {
        let m = scene.markers.map { MarkerGPU(pos: $0.pos, color: $0.color, size: $0.size, pulse: $0.pulse, kind: $0.kind) }
        markerCount = m.count
        markerBuf = m.isEmpty ? nil : device.makeBuffer(bytes: m, length: m.count * MemoryLayout<MarkerGPU>.stride)
    }

    /// Great-circle arc lifted off the surface proportionally to its length.
    static func arcPoints(_ a: SIMD3<Float>, _ bIn: SIMD3<Float>, segments: Int = 72) -> [SIMD3<Float>] {
        var b = bIn
        var d = simd_dot(a, b)
        if d < -0.9995 {   // antipodal: nudge to make the plane well-defined
            b = simd_normalize(b + SIMD3<Float>(0.02, 0.03, 0.0))
            d = simd_dot(a, b)
        }
        let omega = acos(max(-1, min(1, d)))
        guard omega > 0.004 else { return [] }
        let lift = 0.02 + 0.30 * (omega / .pi)
        let s = sin(omega)
        return (0...segments).map { i in
            let t = Float(i) / Float(segments)
            let p = (sin((1 - t) * omega) * a + sin(t * omega) * b) / s
            return simd_normalize(p) * (1.0 + lift * sin(.pi * t))
        }
    }

    // MARK: camera control

    func rotate(dx: Float, dy: Float) {
        let k = 0.0032 * (dist / 5.0)
        yaw -= dx * k
        pitch = max(-1.35, min(1.35, pitch + dy * k))
        velocity = SIMD2(-dx * k, dy * k)
        targetYaw = nil; targetPitch = nil
        lastInteraction = Date()
    }

    func zoom(by factor: Float) {
        dist = max(1.6, min(10.0, dist * factor))
        targetDist = nil
        lastInteraction = Date()
    }

    func focus(lat: Double, lon: Double, distance: Float? = nil) {
        var ty = Float(lon * .pi / 180)
        // choose the equivalent angle nearest the current yaw so we don't spin the long way
        while ty - yaw > .pi { ty -= 2 * .pi }
        while ty - yaw < -.pi { ty += 2 * .pi }
        targetYaw = ty
        targetPitch = max(-1.2, min(1.2, Float(lat * .pi / 180)))
        if let distance { targetDist = distance }
        velocity = .zero
        lastInteraction = Date()
    }

    // MARK: projection helpers (points, origin bottom-left)

    func project(_ p: SIMD3<Float>) -> (point: CGPoint, facing: Float)? {
        let world = model * SIMD4<Float>(p, 1)
        let clip = viewProj * world
        guard clip.w > 0 else { return nil }
        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        let pt = CGPoint(x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width, y: CGFloat(ndc.y * 0.5 + 0.5) * viewSize.height)
        let w = SIMD3<Float>(world.x, world.y, world.z)
        let cam = SIMD3<Float>(0, 0, dist)
        let facing = simd_dot(simd_normalize(w), simd_normalize(cam - w))
        return (pt, facing)
    }

    func hitTest(_ point: CGPoint, radius: CGFloat = 14) -> String? {
        var best: (String, CGFloat)?
        for m in scene.markers {
            guard let (p, facing) = project(m.pos), facing > 0.02 else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < radius + CGFloat(m.size) * 0.25, d < (best?.1 ?? .infinity) { best = (m.id, d) }
        }
        return best?.0
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stepCamera()
        viewSize = view.bounds.size
        let drawable = view.drawableSize
        guard drawable.width > 0, drawable.height > 0,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let aspect = Float(drawable.width / drawable.height)
        let proj = Self.perspective(fovy: fovy, aspect: aspect, near: 0.05, far: 50)
        let viewM = Self.translation(0, 0, -dist)
        model = Self.rotationX(pitch) * Self.rotationY(-yaw)
        viewProj = proj * viewM
        let angular = asin(min(0.999, 1 / dist))
        let radiusPx = tan(angular) / tan(fovy / 2) * Float(drawable.height) / 2
        let now = Float(CACurrentMediaTime() - startTime)

        var u = GlobeUniforms(
            viewProj: viewProj, model: model, cameraPos: SIMD4(0, 0, dist, 1),
            viewport: SIMD2(Float(drawable.width), Float(drawable.height)), time: now,
            pointScale: backingScale,
            globeCenterPx: SIMD2(Float(drawable.width) / 2, Float(drawable.height) / 2),
            globeRadiusPx: radiusPx, zoom: 5.0 / dist, sunDir: SIMD4(Self.sunDirection(), 0),
            bgColor: palette.bg, oceanColor: palette.ocean, landColor: palette.land, lineColor: palette.line,
            flags: SIMD4(palette.dark ? 1 : 0, 0, 0, 0))

        // 1. background + halo
        enc.setRenderPipelineState(atmospherePSO)
        enc.setDepthStencilState(depthOff)
        enc.setFragmentBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. ocean body (writes depth so far-side geometry is occluded)
        enc.setRenderPipelineState(spherePSO)
        enc.setDepthStencilState(depthWrite)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        enc.setVertexBuffer(sphereVB, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereIndexCount, indexType: .uint32, indexBuffer: sphereIB, indexBufferOffset: 0)
        enc.setCullMode(.none)

        // 3. land dots
        if let dotsVB, dotCount > 0 {
            enc.setRenderPipelineState(dotsPSO)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBuffer(dotsVB, offset: 0, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: dotCount)
        }

        // 4. arcs
        if let arcVB, let arcIB, let arcDataBuf, arcIndexCount > 0 {
            enc.setRenderPipelineState(arcPSO)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBuffer(arcVB, offset: 0, index: 1)
            enc.setVertexBuffer(arcDataBuf, offset: 0, index: 2)
            enc.setFragmentBuffer(arcDataBuf, offset: 0, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: arcIndexCount, indexType: .uint32, indexBuffer: arcIB, indexBufferOffset: 0)
        }

        // 5. markers
        if let markerBuf, markerCount > 0 {
            enc.setRenderPipelineState(markerPSO)
            enc.setDepthStencilState(depthOff)
            enc.setVertexBuffer(markerBuf, offset: 0, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: markerCount)
        }

        enc.endEncoding()
        if let d = view.currentDrawable { cb.present(d) }
        cb.commit()
        onFrame?()
    }

    private func stepCamera() {
        if let ty = targetYaw {
            yaw += (ty - yaw) * 0.075
            if abs(ty - yaw) < 0.0005 { targetYaw = nil }
        }
        if let tp = targetPitch {
            pitch += (tp - pitch) * 0.075
            if abs(tp - pitch) < 0.0005 { targetPitch = nil }
        }
        if let td = targetDist {
            dist += (td - dist) * 0.07
            if abs(td - dist) < 0.001 { targetDist = nil }
        }
        if !dragging, targetYaw == nil {
            if simd_length(velocity) > 0.00005 {
                yaw += velocity.x
                pitch = max(-1.35, min(1.35, pitch + velocity.y))
                velocity *= 0.93
            } else if autoRotate, Date().timeIntervalSince(lastInteraction) > 5 {
                yaw += 0.0007
            }
        }
        if yaw > .pi * 4 || yaw < -.pi * 4 { yaw = fmodf(yaw, 2 * .pi) }
    }

    // MARK: math

    /// Model-space unit vector toward the subsolar point (declination + hour angle).
    static func sunDirection(date: Date = Date()) -> SIMD3<Float> {
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = Double(utc.ordinality(of: .day, in: .year, for: date) ?? 1)
        let c = utc.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        let decl = -23.44 * cos(2 * .pi / 365 * (day + 10))
        let lon = -15 * (hours - 12)
        return GeoMath.unitVector(lat: decl, lon: lon)
    }

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovy * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(x, y, z, 1)))
    }

    static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }
}

// MARK: - Land dots

enum LandDots {
    /// Evenly distributed (Fibonacci) points on the sphere, kept where the
    /// equirectangular land mask (row 0 = north) says "land". w = per-dot shimmer seed.
    static func generate(mask px: [UInt8], width w: Int, height h: Int, count: Int = 140_000) -> [SIMD4<Float>] {
        guard px.count == w * h else { return [] }

        var out: [SIMD4<Float>] = []
        out.reserveCapacity(count / 3)
        let golden = Double.pi * (3 - sqrt(5))
        for i in 0..<count {
            let y = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = sqrt(max(0, 1 - y * y))
            let th = golden * Double(i)
            let x = cos(th) * r, z = sin(th) * r
            let lat = asin(y) * 180 / .pi
            let lon = atan2(x, z) * 180 / .pi
            let u = Int((lon + 180) / 360 * Double(w)) % w
            let v = min(h - 1, max(0, Int((90 - lat) / 180 * Double(h))))
            if px[v * w + u] > 127 {
                out.append(SIMD4(Float(x), Float(y), Float(z), Float.random(in: 0...1)))
            }
        }
        return out
    }
}
