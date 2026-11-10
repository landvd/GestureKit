import Cocoa

/// 截图界面：每块屏幕一个遮罩面板（定格画面 + 半黑 + 选框 + 尺寸 + 工具条）。
/// 全部在主线程，不经过事件 tap。面板是 non-activating 的，按快捷键时前台 App 不变。
final class CaptureController {

    static let shared = CaptureController()

    enum Commit: String { case copy, copyAndHang, save, pin, ocr }

    /// 完成截图后要挂到衣架（双击 / ✓ / ⌘S）；第二期由衣架接上
    var onHang: ((CGImage, Data, CGFloat) -> Void)?

    private var panels: [CapturePanel] = []
    private var busy = false
    private var previousApp: NSRunningApplication?

    var isActive: Bool { busy }

    func start() {
        guard !busy else { return }
        guard Capture.hasPermission else { Capture.explainPermission(); return }
        busy = true
        let t0 = CFAbsoluteTimeGetCurrent()
        let windows = Capture.windowRects()
        Task {
            let frozen = await Capture.freezeAll()
            DispatchQueue.main.async { CaptureController.shared.didFreeze(frozen, windows: windows, since: t0) }
        }
    }

    private func didFreeze(_ frozen: [Capture.Frozen], windows: [CGRect], since t0: CFAbsoluteTime) {
        Log.write(String(format: "capture: froze %d screen(s) in %.0f ms",
                         frozen.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        guard !frozen.isEmpty else {
            busy = false
            HUD.shared.show(L("截图失败"), duration: 0.9)
            return
        }
        show(frozen, windows: windows)
    }

    private func show(_ frozen: [Capture.Frozen], windows: [CGRect]) {
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        for f in frozen {
            let local = windows.map { $0.offsetBy(dx: -f.cgBounds.minX, dy: -f.cgBounds.minY) }
            let panel = CapturePanel(frozen: f, windows: local, controller: self)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKey()
        NSApp.activate()
        NSCursor.crosshair.set()
    }

    /// 某块屏幕开始拉新选框：其他屏幕的选框清掉
    func selectionStarted(in view: CaptureOverlayView) {
        for p in panels where p.overlay !== view { p.overlay.reset() }
    }

    func cancel() {
        close()
        Log.write("capture: cancelled")
    }

    func commit(_ kind: Commit, frozen: Capture.Frozen, rect: CGRect) {
        close()
        guard let img = Capture.crop(frozen, rect: rect) else { return }
        let scale = frozen.scale
        if kind == .ocr {                          // 只要文字：不复制图、不挂
            Log.write("capture: ocr \(img.width)x\(img.height)px")
            TextRecognition.copyText(in: img)
            return
        }
        if kind == .pin {                          // 钉在原来的位置
            PinnedImages.shared.pin(img, scale: scale, at: CaptureController.cocoaRect(rect, in: frozen))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let png = Capture.png(img, scale: scale) else { return }
            let saved = kind == .save ? Capture.saveToDesktop(png) : nil
            DispatchQueue.main.async {
                Capture.copyToPasteboard(img, png: png, scale: scale)
                if kind != .copy { self.onHang?(img, png, scale) }
                if kind != .pin { HUD.shared.show(saved != nil ? L("已存到桌面并复制") : L("已复制"), duration: 0.8) }
                Log.write("capture: \(kind.rawValue) \(img.width)x\(img.height)px")
            }
        }
    }

    /// 选框（本屏左上原点）→ Cocoa 全局坐标
    static func cocoaRect(_ r: CGRect, in f: Capture.Frozen) -> NSRect {
        NSRect(x: f.cocoaFrame.minX + r.minX, y: f.cocoaFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func close() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        busy = false
        NSCursor.arrow.set()
        if NSApp.isActive, let prev = previousApp, prev != NSRunningApplication.current { prev.activate() }
        previousApp = nil
    }
}

/// 覆盖整块屏幕的无边框面板；不激活 App 也能收键盘。
final class CapturePanel: NSPanel {

    let overlay: CaptureOverlayView

    init(frozen: Capture.Frozen, windows: [CGRect], controller: CaptureController) {
        overlay = CaptureOverlayView(frozen: frozen, windows: windows, controller: controller)
        super.init(contentRect: frozen.cocoaFrame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = overlay
        setFrame(frozen.cocoaFrame, display: false)
        makeFirstResponder(overlay)
    }

    override var canBecomeKey: Bool { true }
}

/// 画面与交互。视图本身不翻转；选框逻辑用左上原点，进出时换算。
final class CaptureOverlayView: NSView {

    let frozen: Capture.Frozen
    private weak var controller: CaptureController?
    private var sel: CaptureSelection

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let toolbar = NSView()

    private static let accent = NSColor.systemGreen
    private static let buttonSize = NSSize(width: 34, height: 30)

    init(frozen: Capture.Frozen, windows: [CGRect], controller: CaptureController) {
        self.frozen = frozen
        self.controller = controller
        sel = CaptureSelection(bounds: CGRect(origin: .zero, size: frozen.cgBounds.size), windows: windows)
        super.init(frame: NSRect(origin: .zero, size: frozen.cocoaFrame.size))
        wantsLayer = true
        setupLayers()
        setupToolbar()
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Setup

    private func setupLayers() {
        guard let root = layer else { return }
        imageLayer.contents = frozen.image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        borderLayer.strokeColor = CaptureOverlayView.accent.cgColor
        borderLayer.lineWidth = 1.5
        handleLayer.fillColor = CaptureOverlayView.accent.cgColor
        handleLayer.strokeColor = NSColor.white.cgColor
        handleLayer.lineWidth = 1
        for l in [imageLayer, dimLayer, borderLayer, handleLayer] as [CALayer] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull()]
            root.addSublayer(l)
        }
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.drawsBackground = true
        sizeLabel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        sizeLabel.isBezeled = false
        sizeLabel.isHidden = true
        addSubview(sizeLabel)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    private func setupToolbar() {
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        toolbar.layer?.cornerRadius = 6
        let items: [(String, String, Selector)] = [
            ("pin", L("钉在屏幕上（P）"), #selector(pinClicked)),
            ("text.viewfinder", L("识别文字并复制（T）"), #selector(ocrClicked)),
            ("square.and.arrow.down", L("存到桌面（⌘S）"), #selector(saveClicked)),
            ("xmark", L("取消（Esc）"), #selector(cancelClicked)),
            ("checkmark", L("完成：复制并挂到衣架（双击框内）；回车只复制"), #selector(doneClicked)),
        ]
        let s = CaptureOverlayView.buttonSize
        for (i, (symbol, tip, action)) in items.enumerated() {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.contentTintColor = symbol == "checkmark" ? CaptureOverlayView.accent : .white
            b.toolTip = tip
            b.frame = NSRect(x: CGFloat(i) * s.width, y: 0, width: s.width, height: s.height)
            toolbar.addSubview(b)
        }
        toolbar.frame.size = NSSize(width: s.width * CGFloat(items.count), height: s.height)
        toolbar.isHidden = true
        addSubview(toolbar)
    }

    // MARK: - Coordinates

    private var H: CGFloat { bounds.height }
    private func top(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }
    private func cocoa(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
    private func point(_ e: NSEvent) -> CGPoint { top(convert(e.locationInWindow, from: nil)) }

    // MARK: - Drawing

    func reset() {
        _ = sel.escape()
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hole = sel.rect ?? sel.hovered
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addRect(cocoa(hole)) }
        dimLayer.path = dim
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        handleLayer.frame = bounds
        borderLayer.path = hole.map { CGPath(rect: cocoa($0).insetBy(dx: 0.75, dy: 0.75), transform: nil) }

        let showHandles = sel.rect != nil && sel.phase != .idle && !isDrawing
        if showHandles, let r = sel.rect {
            let hp = CGMutablePath()
            for (_, c) in CaptureSelection.handlePoints(r) {
                let p = NSPoint(x: c.x, y: H - c.y)
                hp.addEllipse(in: NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            }
            handleLayer.path = hp
        } else {
            handleLayer.path = nil
        }
        CATransaction.commit()

        if let r = sel.rect {
            sizeLabel.stringValue = " \(Int(r.width.rounded())) × \(Int(r.height.rounded())) "
            sizeLabel.sizeToFit()
            let o = CaptureSelection.sizeLabelOrigin(for: r, size: sizeLabel.frame.size, in: sel.bounds)
            sizeLabel.frame.origin = NSPoint(x: o.x, y: H - o.y - sizeLabel.frame.height)
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }
        if let r = sel.rect, sel.phase == .selected {
            let f = CaptureSelection.toolbarFrame(for: r, size: toolbar.frame.size, in: sel.bounds)
            toolbar.frame = cocoa(f)
            toolbar.isHidden = false
        } else {
            toolbar.isHidden = true
        }
    }

    private var isDrawing: Bool { if case .drawing = sel.phase { return true }; return false }

    // MARK: - Mouse

    override func mouseMoved(with e: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
        sel.hover(point(e))
        updateCursor(point(e))
        update()
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(point(event)) }

    private func updateCursor(_ p: CGPoint) {
        guard sel.phase == .selected, let h = sel.handle(at: p) else { NSCursor.crosshair.set(); return }
        let pos: NSCursor.FrameResizePosition
        switch h {
        case .inside:      NSCursor.openHand.set(); return
        case .topLeft:     pos = .topLeft
        case .top:         pos = .top
        case .topRight:    pos = .topRight
        case .right:       pos = .right
        case .bottomRight: pos = .bottomRight
        case .bottom:      pos = .bottom
        case .bottomLeft:  pos = .bottomLeft
        case .left:        pos = .left
        }
        NSCursor.frameResize(position: pos, directions: .all).set()
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        let p = point(e)
        if sel.mouseDown(p, clickCount: e.clickCount) == .confirm {
            finish(.copyAndHang)
            return
        }
        if isDrawing { controller?.selectionStarted(in: self) }
        if case .adjusting(.inside, _, _) = sel.phase { NSCursor.closedHand.set() }
        update()
    }

    override func mouseDragged(with e: NSEvent) {
        sel.mouseDragged(point(e))
        update()
    }

    override func mouseUp(with e: NSEvent) {
        sel.mouseUp(point(e))
        updateCursor(point(e))
        update()
    }

    override func rightMouseDown(with e: NSEvent) { controller?.cancel() }

    // MARK: - Keyboard

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        let resize = e.modifierFlags.contains(.option)
        switch e.keyCode {
        case 53:                                   // Esc
            if sel.escape() { controller?.cancel() } else { update() }
        case 36, 76:                               // Return / Enter：只复制
            finish(.copy)
        case 1 where cmd:                          // ⌘S
            finish(.save)
        case 35 where !cmd:                        // P：钉在屏幕上
            finish(.pin)
        case 17 where !cmd:                        // T：识别文字
            finish(.ocr)
        case 123: sel.nudge(dx: -step, dy: 0, resize: resize); update()
        case 124: sel.nudge(dx: step, dy: 0, resize: resize); update()
        case 125: sel.nudge(dx: 0, dy: step, resize: resize); update()
        case 126: sel.nudge(dx: 0, dy: -step, resize: resize); update()
        default: break
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command), e.keyCode == 1 { finish(.save); return true }
        return super.performKeyEquivalent(with: e)
    }

    private func finish(_ kind: CaptureController.Commit) {
        guard let r = sel.rect, sel.phase == .selected else { return }
        controller?.commit(kind, frozen: frozen, rect: r)
    }

    @objc private func saveClicked() { finish(.save) }
    @objc private func pinClicked() { finish(.pin) }
    @objc private func ocrClicked() { finish(.ocr) }
    @objc private func cancelClicked() { controller?.cancel() }
    @objc private func doneClicked() { finish(.copyAndHang) }
}
