// Renders NetLens's app icon into NetLens/Assets.xcassets/AppIcon.appiconset.
//   swift scripts/make-icon.swift
//
// The mark: a lens over a network path. The path traces the letter N through four hops,
// the last one (the destination) haloed; a faint globe grid sits behind it in the glass.
import AppKit

struct Palette {
    var bgTop: NSColor, bgBottom: NSColor
    var ring: NSColor, glassTop: NSColor, glassBottom: NSColor
    var path: NSColor, node: NSColor, nodeCore: NSColor, dest: NSColor
}

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
}

func lin(_ ctx: CGContext, _ c1: NSColor, _ c2: NSColor, from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func render(_ px: Int, _ p: Palette) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.setShouldAntialias(true)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    // drop shadow (macOS grid convention)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape); ctx.setFillColor(p.bgBottom.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    lin(ctx, p.bgTop, p.bgBottom, from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // faint top sheen
    lin(ctx, NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0), from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 640))

    let c = CGPoint(x: 512, y: 512)
    let R: CGFloat = 300           // ring centre-line radius
    let ringW: CGFloat = 34
    let glassR = R - ringW / 2

    // lens glass
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - glassR, y: c.y - glassR, width: 2 * glassR, height: 2 * glassR)); ctx.clip()
    lin(ctx, p.glassTop, p.glassBottom, from: CGPoint(x: c.x - glassR, y: c.y + glassR), to: CGPoint(x: c.x + glassR, y: c.y - glassR))
    // soft reflection crescent, top-left
    ctx.saveGState()
    let refl = CGMutablePath()
    refl.addEllipse(in: CGRect(x: c.x - glassR * 0.98, y: c.y - glassR * 0.55, width: glassR * 1.9, height: glassR * 1.62))
    let cut = CGMutablePath()
    cut.addEllipse(in: CGRect(x: c.x - glassR * 0.80, y: c.y - glassR * 0.90, width: glassR * 2.1, height: glassR * 1.75))
    ctx.addPath(refl); ctx.clip()
    ctx.addPath(cut); ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024)); ctx.clip(using: .evenOdd)
    lin(ctx, NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.0), from: CGPoint(x: c.x - glassR, y: c.y + glassR), to: CGPoint(x: c.x, y: c.y))
    ctx.restoreGState()
    // faint globe graticule behind the path
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
    ctx.setLineWidth(5)
    for k in [1, 2] {
        let mw = glassR * 2 * sin(CGFloat(k) * .pi / 6)
        ctx.strokeEllipse(in: CGRect(x: c.x - mw / 2, y: c.y - glassR, width: mw, height: 2 * glassR))
    }
    for k in [-2, -1, 0, 1, 2] {
        let y = c.y + CGFloat(k) * glassR / 3
        let half = sqrt(max(0, glassR * glassR - (y - c.y) * (y - c.y)))
        ctx.move(to: CGPoint(x: c.x - half, y: y)); ctx.addLine(to: CGPoint(x: c.x + half, y: y))
    }
    ctx.strokePath()
    // the ring casts a soft shadow onto the glass
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.setStrokeColor(NSColor.black.cgColor)
    ctx.setLineWidth(40)
    ctx.strokeEllipse(in: CGRect(x: c.x - glassR - 20, y: c.y - glassR - 20, width: 2 * glassR + 40, height: 2 * glassR + 40))
    ctx.restoreGState()
    ctx.restoreGState()

    // ring
    ctx.saveGState()
    ctx.setLineWidth(ringW)
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.replacePathWithStrokedPath(); ctx.clip()
    lin(ctx, p.ring, p.ring.blended(withFraction: 0.22, of: .black)!, from: CGPoint(x: c.x, y: c.y + R), to: CGPoint(x: c.x, y: c.y - R))
    ctx.restoreGState()
    // inner hairline for lens depth
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: CGRect(x: c.x - glassR + 2, y: c.y - glassR + 2, width: 2 * glassR - 4, height: 2 * glassR - 4))

    // N as a network path: A (bottom-left) → B (top-left) → C (bottom-right) → D (top-right)
    let w: CGFloat = 104, h: CGFloat = 118
    let A = CGPoint(x: c.x - w, y: c.y - h), B = CGPoint(x: c.x - w, y: c.y + h)
    let C = CGPoint(x: c.x + w, y: c.y - h), D = CGPoint(x: c.x + w, y: c.y + h)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(p.path.cgColor)
    ctx.setLineWidth(30)
    ctx.move(to: A); ctx.addLine(to: B); ctx.addLine(to: C); ctx.addLine(to: D)
    ctx.strokePath()
    let nodeR: CGFloat = 36
    for (i, pt) in [A, B, C, D].enumerated() {
        let isDest = i == 3
        if isDest {   // the destination: solid, with a halo
            ctx.setStrokeColor(p.dest.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(9)
            let hr = nodeR + 22
            ctx.strokeEllipse(in: CGRect(x: pt.x - hr, y: pt.y - hr, width: 2 * hr, height: 2 * hr))
        }
        ctx.setFillColor((isDest ? p.dest : p.node).cgColor)
        ctx.fillEllipse(in: CGRect(x: pt.x - nodeR, y: pt.y - nodeR, width: 2 * nodeR, height: 2 * nodeR))
        if !isDest {
            ctx.setFillColor(p.nodeCore.cgColor)
            let r2: CGFloat = 15
            ctx.fillEllipse(in: CGRect(x: pt.x - r2, y: pt.y - r2, width: 2 * r2, height: 2 * r2))
        }
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let graphite = Palette(bgTop: rgb(0x3B4048), bgBottom: rgb(0x15171B),
                       ring: rgb(0xF2F4F7), glassTop: rgb(0x2F7BFF), glassBottom: rgb(0x0B45C7),
                       path: .white, node: .white, nodeCore: rgb(0x0E4CD2), dest: .white)

let out = URL(fileURLWithPath: "NetLens/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! render(pt * sc, graphite).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(sc)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
let root: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
    .write(to: out.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote", images.count, "icons")
