import SwiftUI
import MetalKit
import AppKit

/// Owns the Metal view + renderer and bridges selection back to SwiftUI.
@MainActor
final class GlobeController {
    let container = GlobeContainerView()
    let renderer: GlobeRenderer?
    var onSelect: ((String?) -> Void)?
    var onHover: ((String?) -> Void)?

    init() {
        renderer = GlobeRenderer(view: container.mtk)
        container.mtk.delegate = renderer
        container.controller = self
        renderer?.onFrame = { [weak self] in self?.container.labels.update(renderer: self?.renderer) }
    }

    func setScene(_ s: GlobeSceneSpec) { renderer?.setScene(s) }

    func select(_ id: String?) {
        renderer?.selectedID = id
        container.labels.selectedID = id
    }

    func focus(lat: Double, lon: Double, distance: Float? = nil) {
        renderer?.focus(lat: lat, lon: lon, distance: distance)
    }

    func resetView(lat: Double?, lon: Double?) {
        renderer?.focus(lat: (lat ?? 20) * 0.8, lon: lon ?? 0, distance: 5.0)
    }

    func zoom(_ factor: Float) { renderer?.zoom(by: factor) }

    var autoRotate: Bool {
        get { renderer?.autoRotate ?? false }
        set { renderer?.autoRotate = newValue }
    }
}

struct GlobeViewRepresentable: NSViewRepresentable {
    let controller: GlobeController
    func makeNSView(context: Context) -> GlobeContainerView { controller.container }
    func updateNSView(_ nsView: GlobeContainerView, context: Context) {}
}

final class GlobeContainerView: NSView {
    let mtk = InteractiveMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    let labels = GlobeLabelOverlay()
    weak var controller: GlobeController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mtk.translatesAutoresizingMaskIntoConstraints = false
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mtk)
        addSubview(labels)
        for v in [mtk, labels] as [NSView] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        mtk.container = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    func applyAppearance() {
        let palette = GlobePalette.current(for: effectiveAppearance)
        controller?.renderer?.palette = palette
        mtk.clearColor = MTLClearColor(red: Double(palette.bg.x), green: Double(palette.bg.y), blue: Double(palette.bg.z), alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        labels.appearanceChanged(effectiveAppearance)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = Float(window?.backingScaleFactor ?? 2)
        controller?.renderer?.backingScale = scale
        labels.scale = CGFloat(scale)
    }
}

final class InteractiveMTKView: MTKView {
    weak var container: GlobeContainerView?
    private var dragDistance: CGFloat = 0
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var renderer: GlobeRenderer? { container?.controller?.renderer }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseDown(with event: NSEvent) {
        dragDistance = 0
        renderer?.dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragDistance += abs(event.deltaX) + abs(event.deltaY)
        renderer?.rotate(dx: Float(event.deltaX), dy: Float(event.deltaY))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        renderer?.dragging = false
        NSCursor.arrow.set()
        guard dragDistance < 4 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = renderer?.hitTest(p)
        if event.clickCount == 2, hit == nil {
            renderer?.zoom(by: 0.75)
            return
        }
        container?.controller?.onSelect?(hit)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = renderer?.hitTest(p)
        if renderer?.hoveredID != hit {
            renderer?.hoveredID = hit
            container?.labels.hoveredID = hit
            container?.controller?.onHover?(hit)
        }
        (hit == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        renderer?.hoveredID = nil
        container?.labels.hoveredID = nil
        NSCursor.arrow.set()
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        renderer?.zoom(by: Float(exp(-Double(dy) * 0.006)))
    }

    override func magnify(with event: NSEvent) {
        renderer?.zoom(by: Float(1 - event.magnification))
    }
}

/// Text labels for markers, drawn as Core Animation layers above the Metal view
/// (crisp text, no SwiftUI diffing at 60 fps). Greedy placement avoids overlaps.
final class GlobeLabelOverlay: NSView {
    var scale: CGFloat = 2
    var selectedID: String?
    var hoveredID: String?
    var maxLabels = 14
    private var layers: [String: CALayer] = [:]
    private var texts: [String: String] = [:]
    private var appearanceRef: NSAppearance = NSAppearance(named: .aqua)!

    func appearanceChanged(_ a: NSAppearance) {
        appearanceRef = a
        for l in layers.values { l.removeFromSuperlayer() }
        layers = [:]
        texts = [:]
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @MainActor
    func update(renderer: GlobeRenderer?) {
        guard let renderer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let candidates = renderer.scene.markers.filter { $0.label != nil }
        var ordered = candidates.sorted { a, b in
            let pa = priority(a), pb = priority(b)
            return pa > pb
        }
        if ordered.count > maxLabels + 2 { ordered = Array(ordered.prefix(maxLabels + 2)) }

        var placed: [CGRect] = []
        var visible = Set<String>()
        for m in ordered {
            guard let (p, facing) = renderer.project(m.pos), facing > 0.18 else { continue }
            let text = m.label!
            let layer = labelLayer(id: m.id, text: text, color: m.labelColor, emphasized: m.id == selectedID || m.id == hoveredID)
            let size = layer.bounds.size
            var frame = CGRect(x: p.x + 10, y: p.y - size.height / 2, width: size.width, height: size.height)
            if frame.maxX > bounds.width - 8 { frame.origin.x = p.x - 10 - size.width }
            let mustShow = m.id == selectedID || m.id == hoveredID || m.kind == 1
            if !mustShow && placed.contains(where: { $0.insetBy(dx: -3, dy: -2).intersects(frame) }) { continue }
            placed.append(frame)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
            layer.opacity = Float(min(1, (facing - 0.18) * 4))
            visible.insert(m.id)
        }
        for (id, l) in layers where !visible.contains(id) { l.opacity = 0 }
        // Drop layers for markers that no longer exist.
        let ids = Set(renderer.scene.markers.map(\.id))
        for id in layers.keys where !ids.contains(id) {
            layers[id]?.removeFromSuperlayer()
            layers[id] = nil
            texts[id] = nil
        }
    }

    private func priority(_ m: GlobeMarkerSpec) -> Int {
        if m.id == selectedID { return Int.max }
        if m.id == hoveredID { return Int.max - 1 }
        if m.kind == 1 { return Int.max - 2 }
        return m.labelPriority
    }

    private func labelLayer(id: String, text: String, color: NSColor, emphasized: Bool) -> CALayer {
        let key = text + (emphasized ? "!" : "")
        if let l = layers[id], texts[id] == key { return l }
        layers[id]?.removeFromSuperlayer()

        var textColor = CGColor(gray: 0, alpha: 1), bgColor = textColor, borderColor = textColor
        var attr = NSAttributedString()
        appearanceRef.performAsCurrentDrawingAppearance {
            let font = NSFont.systemFont(ofSize: 11, weight: emphasized ? .semibold : .medium)
            attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            textColor = NSColor.labelColor.cgColor
            bgColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
            borderColor = (emphasized ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
        _ = textColor
        let ts = attr.size()
        let padX: CGFloat = 6, padY: CGFloat = 2.5
        let bg = CALayer()
        bg.bounds = CGRect(x: 0, y: 0, width: ceil(ts.width) + padX * 2, height: ceil(ts.height) + padY * 2)
        bg.backgroundColor = bgColor
        bg.borderColor = borderColor
        bg.borderWidth = emphasized ? 1 : 0.5
        bg.cornerRadius = 5
        bg.contentsScale = scale
        let tl = CATextLayer()
        tl.string = attr
        tl.contentsScale = scale
        tl.frame = CGRect(x: padX, y: padY - 0.5, width: ceil(ts.width) + 1, height: ceil(ts.height))
        bg.addSublayer(tl)
        layer?.addSublayer(bg)
        layers[id] = bg
        texts[id] = key
        return bg
    }
}
