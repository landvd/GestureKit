import Cocoa

/// Draws the chord stroke on screen while the gesture is held (通用设置 → 显示轨迹).
/// One click-through panel that covers only the stroke drawn so far (it grows in
/// steps as the stroke does) and a GPU shape layer; it fades out when the chord ends.
/// Fed by `GestureEngine.onChordStroke`.
///
/// Why not a full-screen panel: on a 4K display that is a 100+ MB transparent surface,
/// and redrawing it in `draw(_:)` on every mouse move stalled the main thread — which is
/// also where the event tap runs — so the cursor and the settings window lagged.
final class GestureTrail {

    static let shared = GestureTrail()

    private var panel: NSPanel?
    private var view: TrailView?
    private var generation = 0
    private var drawing = false

    /// Create the (hidden) panel at launch, not on the first stroke.
    func prepare() { _ = ensurePanel() }

    /// `points` are CG global coordinates (top-left origin), as the engine records them.
    func update(_ points: [CGPoint], finished: Bool, config: TrailConfig) {
        guard points.count >= 2 else { if finished { fadeOut() }; return }
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let (panel, view) = ensurePanel()
        let width = CGFloat(max(1, min(10, config.width)))
        let needed = GestureTrail.bounds(points, mainHeight: mainHeight, margin: width + 4)

        if !drawing {
            drawing = true
            generation += 1
            panel.setFrame(GestureTrail.grown(.null, toFit: needed), display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else if !panel.frame.contains(needed) {
            panel.setFrame(GestureTrail.grown(panel.frame, toFit: needed), display: false)
        }
        view.show(GestureTrail.localPoints(points, screenFrame: panel.frame, mainHeight: mainHeight),
                  color: GestureTrail.color(hex: config.color) ?? .systemTeal, width: width)

        if finished { fadeOut() }
    }

    private func fadeOut() {
        drawing = false
        guard let panel else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == gen else { return }   // a new stroke started meanwhile
            panel.orderOut(nil)
            self.view?.clear()
        })
    }

    private func ensurePanel() -> (NSPanel, TrailView) {
        if let panel, let view { return (panel, view) }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let v = TrailView()
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        panel = p
        view = v
        return (p, v)
    }

    // MARK: - Pure helpers (selftest)

    /// Cocoa (bottom-left) rect around CG global points, plus `margin` on every side.
    static func bounds(_ cg: [CGPoint], mainHeight: CGFloat, margin: CGFloat) -> CGRect {
        let xs = cg.map(\.x), ys = cg.map { mainHeight - $0.y }
        return CGRect(x: xs.min()! - margin, y: ys.min()! - margin,
                      width: xs.max()! - xs.min()! + 2 * margin, height: ys.max()! - ys.min()! + 2 * margin)
    }

    /// Panel frame that holds `needed`: the current one widened with 160 pt of slack on
    /// each side, so a growing stroke resizes the panel a few times, not on every move.
    static func grown(_ current: CGRect, toFit needed: CGRect) -> CGRect {
        let base = current.isNull ? needed : current.union(needed)
        return base.insetBy(dx: -160, dy: -160).integral
    }

    /// CG global points → coordinates inside a view covering `screenFrame` (Cocoa).
    static func localPoints(_ cg: [CGPoint], screenFrame: CGRect, mainHeight: CGFloat) -> [CGPoint] {
        cg.map { CGPoint(x: $0.x - screenFrame.minX, y: mainHeight - $0.y - screenFrame.minY) }
    }

    /// "#RRGGBB" / "RRGGBB" → sRGB colour.
    static func color(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#87D9FF" }
        func byte(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Layer-backed: the stroke is a CAShapeLayer path (rendered by the GPU / WindowServer),
/// so a new point never makes the view redraw its pixels.
private final class TrailView: NSView {
    private let halo = CAShapeLayer()
    private let line = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        for l in [halo, line] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            layer?.addSublayer(l)
        }
        // Thin dark halo keeps a light trail visible on white pages.
        halo.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.frame = bounds; line.frame = bounds
        CATransaction.commit()
    }

    func show(_ points: [CGPoint], color: NSColor, width: CGFloat) {
        let path = CGMutablePath()
        path.addLines(between: points)
        CATransaction.begin(); CATransaction.setDisableActions(true)   // no implicit animation per point
        halo.frame = bounds; line.frame = bounds
        halo.lineWidth = width + 2
        line.lineWidth = width
        line.strokeColor = color.cgColor
        halo.path = path
        line.path = path
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.path = nil; line.path = nil
        CATransaction.commit()
    }
}
