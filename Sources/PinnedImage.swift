import Cocoa

/// 钉在屏幕上的截图：置顶浮窗，拖动移动、滚轮缩放、双击 / Esc / ✕ 关闭、⌘C 复制。
/// 可以同时钉多张。图片本身已经在衣架上，关掉浮窗不会丢。
final class PinnedImages {

    static let shared = PinnedImages()
    static let zoomRange: ClosedRange<CGFloat> = 0.25...4

    private var panels: [PinnedPanel] = []

    /// at：Cocoa 坐标里的位置（截图时就是选框原来的位置）；nil = 光标所在屏幕正中
    func pin(_ image: CGImage, scale: CGFloat, at frame: NSRect? = nil) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let rect = frame ?? PinnedImages.centered(size, in: mouseScreen().visibleFrame)
        let p = PinnedPanel(image: image, pointSize: size, frame: rect) { [weak self] panel in
            self?.panels.removeAll { $0 === panel }
        }
        panels.append(p)
        p.makeKeyAndOrderFront(nil)
        Log.write("pin: \(image.width)x\(image.height)px, \(panels.count) pinned")
    }

    var count: Int { panels.count }

    /// 放在屏幕正中，太大就缩到屏幕的 60% 以内
    static func centered(_ size: NSSize, in screen: NSRect) -> NSRect {
        let k = min(1, screen.width * 0.6 / max(size.width, 1), screen.height * 0.6 / max(size.height, 1))
        let s = NSSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        return NSRect(x: (screen.midX - s.width / 2).rounded(), y: (screen.midY - s.height / 2).rounded(),
                      width: s.width, height: s.height)
    }

    /// 以 anchor（屏幕坐标）为中心缩放：anchor 下的那一点保持不动
    static func zoomed(_ frame: NSRect, base: NSSize, to zoom: CGFloat, anchor: NSPoint) -> NSRect {
        let z = min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
        let w = (base.width * z).rounded(), h = (base.height * z).rounded()
        let fx = frame.width > 0 ? (anchor.x - frame.minX) / frame.width : 0.5
        let fy = frame.height > 0 ? (anchor.y - frame.minY) / frame.height : 0.5
        return NSRect(x: (anchor.x - fx * w).rounded(), y: (anchor.y - fy * h).rounded(), width: w, height: h)
    }

    private func mouseScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

final class PinnedPanel: NSPanel {

    let image: CGImage
    /// 100% 时的大小（点）
    let base: NSSize
    private(set) var zoom: CGFloat
    private let onClose: (PinnedPanel) -> Void

    init(image: CGImage, pointSize: NSSize, frame: NSRect, onClose: @escaping (PinnedPanel) -> Void) {
        self.image = image
        self.base = pointSize
        self.zoom = pointSize.width > 0 ? frame.width / pointSize.width : 1
        self.onClose = onClose
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = PinnedView(panel: self)
    }

    override var canBecomeKey: Bool { true }

    func setZoom(_ z: CGFloat, anchor: NSPoint) {
        let nz = min(max(z, PinnedImages.zoomRange.lowerBound), PinnedImages.zoomRange.upperBound)
        guard nz != zoom else { return }
        zoom = nz
        setFrame(PinnedImages.zoomed(frame, base: base, to: nz, anchor: anchor), display: true)
        HUD.shared.show("\(Int((nz * 100).rounded()))%", duration: 0.5)
    }

    func closePin() {
        orderOut(nil)
        onClose(self)
    }

    func copyImage() {
        let scale = CGFloat(image.width) / max(base.width, 1)
        guard let png = Capture.png(image, scale: scale) else { return }
        Capture.copyToPasteboard(image, png: png, scale: scale)
        HUD.shared.show(L("已复制"), duration: 0.7)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { closePin(); return }                              // Esc
        if e.modifierFlags.contains(.command), e.keyCode == 8 { copyImage(); return }   // ⌘C
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 8 { copyImage(); return true }
        if e.modifierFlags.contains(.command), e.keyCode == 13 { closePin(); return true }  // ⌘W
        return super.performKeyEquivalent(with: e)
    }
}

private final class PinnedView: NSView {

    private weak var panel: PinnedPanel?
    private let closeButton = NSButton()

    init(panel: PinnedPanel) {
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.contents = panel.image
        layer?.contentsGravity = .resize
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("关闭"))
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = L("关闭（Esc / 双击）")
        closeButton.isHidden = true
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        closeButton.frame = NSRect(x: bounds.width - 22, y: bounds.height - 22, width: 18, height: 18)
        closeButton.wantsLayer = true
        closeButton.layer?.shadowOpacity = 0.6
        closeButton.layer?.shadowRadius = 2
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 手动拖动（不用 isMovableByWindowBackground：它会吃掉双击）
    private var dragOffset: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        if e.clickCount >= 2 { panel?.closePin(); return }
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - w.frame.minX, y: m.y - w.frame.minY)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let o = dragOffset else { return }
        let m = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: m.x - o.x, y: m.y - o.y))
    }

    override func mouseUp(with e: NSEvent) { dragOffset = nil }

    override func scrollWheel(with e: NSEvent) {
        guard let panel else { return }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 40 : e.scrollingDeltaY / 4
        guard dy != 0 else { return }
        panel.setZoom(panel.zoom * pow(1.1, dy), anchor: NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add(L("复制"), #selector(copyImage))
        add(L("识别文字"), #selector(recognize))
        add(L("原始大小"), #selector(actualSize))
        m.addItem(.separator())
        add(L("关闭"), #selector(close))
        return m
    }

    @objc private func copyImage() { panel?.copyImage() }
    @objc private func recognize() { if let img = panel?.image { TextRecognition.copyText(in: img) } }
    @objc private func actualSize() {
        guard let panel else { return }
        panel.setZoom(1, anchor: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
    }
    @objc private func close() { panel?.closePin() }
}
