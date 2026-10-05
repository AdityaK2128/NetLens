// Renders NetLens's app icon into NetLens/Assets.xcassets/AppIcon.appiconset.
//   swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "NetLens/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Squircle body on Apple's 1024 grid (824 pt body, 100 pt margin).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Globe.
    let c = CGPoint(x: 512, y: 512), r: CGFloat = 268
    let globe = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
    ctx.saveGState()
    ctx.addPath(globe); ctx.clip()
    let blue = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.30, green: 0.60, blue: 1.0, alpha: 1).cgColor,
                                   NSColor(red: 0.07, green: 0.36, blue: 0.86, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(blue, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
    // graticule
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    ctx.setLineWidth(7)
    for k in [-2, -1, 0, 1, 2] {
        let mw = r * 2 * abs(sin(CGFloat(k + 3) * .pi / 6))
        ctx.addEllipse(in: CGRect(x: c.x - mw / 2, y: c.y - r, width: mw, height: 2 * r))
    }
    for k in [-2, -1, 1, 2] {
        let y = c.y + CGFloat(k) * r / 3
        ctx.move(to: CGPoint(x: c.x - r, y: y)); ctx.addLine(to: CGPoint(x: c.x + r, y: y))
    }
    ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
    ctx.strokePath()
    ctx.restoreGState()

    // A connection arc leaving the globe — the "lens" on your traffic.
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 360, y: 420))
    ctx.addQuadCurve(to: CGPoint(x: 690, y: 640), control: CGPoint(x: 470, y: 760))
    ctx.strokePath()
    for p in [CGPoint(x: 360, y: 420), CGPoint(x: 690, y: 640)] {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52))
        ctx.setFillColor(NSColor(red: 0.07, green: 0.36, blue: 0.86, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"
        try! draw(pt * sc).write(to: out.appendingPathComponent(name))
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
