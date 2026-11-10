import Carbon
import Cocoa

/// 截图衣架的界面与开合。全部在主线程，不经过事件 tap：
/// 悬停检测用 NSEvent 的全局 / 本地监听（只读，不吞事件），开合用计时。
final class ClotheslineController: NSObject {

    static let shared = ClotheslineController()
    /// 「显示/隐藏截图衣架」动作发出
    static let toggleNotification = Notification.Name("GestureKit.toggleClothesline")
    /// ⌃⌥T（kVK_ANSI_T = 17）
    static let hotkeyKeyCode: UInt32 = 17
    static let hotkeyModifiers: UInt32 = UInt32(controlKey | optionKey)

    lazy var store = ClotheslineStore()   // --clothesline-demo 换成临时文件夹

    private var panel: NSPanel?
    private var lineView: ClotheslineView?
    private var monitors: [Any] = []
    private var zones: [(CGRect, NSScreen)] = []
    private var dwellWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var autoHideWork: DispatchWorkItem?
    /// ⌃⌥T 打开的：鼠标进来过之前不自动收起
    private var sticky = false
    private var mouseEntered = false
    /// 正在从卡片往外拖：不收起
    var dragging = false
    private(set) var isShown = false
    private(set) var enabled = false
    /// 衣架样式（设置或衣架右键改）；换了就重摆
    var style: ClotheslineStyle = .default {
        didSet { if style != oldValue { lineView?.restyle() } }
    }
    /// 衣架右键选了样式：AppDelegate 写进配置（再经 applyClothesline 设回 style）
    var onStyleChange: ((ClotheslineStyle) -> Void)?

    // MARK: - Lifecycle

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            rebuildZones()
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) {
                monitors.append(g)
            }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.mouseMoved(); return e }) {
                monitors.append(l)
            }
            if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                self?.clickedElsewhere()
            }) { monitors.append(c) }
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                                   name: NSApplication.didChangeScreenParametersNotification, object: nil)
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
            hide(animated: false)
        }
        Log.write("clothesline: \(on ? "on" : "off") (\(store.items.count) item(s))")
    }

    @objc private func screensChanged() {
        rebuildZones()
        if isShown { hide(animated: false) }
    }

    private func rebuildZones() {
        zones = NSScreen.screens.map { (ClotheslineTrigger.zone(screen: $0.frame, visible: $0.visibleFrame), $0) }
    }

    // MARK: - Public

    /// 截图完成后挂上一张：短暂展开衣架看它落下
    func hang(_ image: CGImage, png: Data, scale: CGFloat) {
        guard enabled, let item = store.add(png: png, pixelWidth: image.width, pixelHeight: image.height,
                                            scale: Double(scale)) else { return }
        Log.write("clothesline: hung \(image.width)x\(image.height)px, \(store.items.count) item(s)")
        if isShown { lineView?.reload(dropping: item.id); return }
        show(on: mouseScreen(), dropping: item.id)
        scheduleAutoHide(1.6)
    }

    func toggle() {
        guard enabled else { return }
        if isShown { hide(animated: true); return }
        show(on: mouseScreen(), dropping: nil)
        sticky = true
    }

    func reload() { lineView?.reload(dropping: nil) }

    // MARK: - Hover

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if isShown {
            let inside = (panel?.frame.contains(p) ?? false) || zones.contains { $0.0.contains(p) }
            if inside {
                mouseEntered = mouseEntered || (panel?.frame.contains(p) ?? false)
                if mouseEntered { sticky = false; autoHideWork?.cancel() }
                leaveWork?.cancel(); leaveWork = nil
            } else if leaveWork == nil, !sticky, !dragging, autoHideWork == nil || mouseEntered {
                let w = DispatchWorkItem { [weak self] in self?.leaveWork = nil; self?.hide(animated: true) }
                leaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + ClotheslineTrigger.leaveDelay, execute: w)
            }
            return
        }
        guard let (_, screen) = zones.first(where: { $0.0.contains(p) }) else {
            dwellWork?.cancel(); dwellWork = nil
            return
        }
        guard dwellWork == nil, !CaptureController.shared.isActive else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellWork = nil
            guard self.zones.contains(where: { $0.0.contains(NSEvent.mouseLocation) }) else { return }
            self.show(on: screen, dropping: nil)
        }
        dwellWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + ClotheslineTrigger.dwell, execute: w)
    }

    private func clickedElsewhere() {
        guard isShown, !dragging, let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        hide(animated: true)
    }

    private func scheduleAutoHide(_ seconds: TimeInterval) {
        autoHideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoHideWork = nil
            if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) { return }
            self.hide(animated: true)
        }
        autoHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// --clothesline-demo：固定在主屏，方便截图对比
    var demoOnMainScreen = false

    private func mouseScreen() -> NSScreen {
        if demoOnMainScreen, let main = NSScreen.screens.first { return main }
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Show / hide

    private func show(on screen: NSScreen, dropping: String?) {
        let panel = self.panel ?? makePanel()
        let width = ClotheslineLayout.panelWidth(screenWidth: screen.frame.width, count: store.items.count)
        let h = ClotheslineLayout.panelHeight
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - h, width: width, height: h), display: false)
        lineView?.frame = NSRect(origin: .zero, size: panel.frame.size)
        lineView?.reload(dropping: dropping)
        if !isShown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
            if dropping == nil { lineView?.swingAll() }
        }
        isShown = true
        mouseEntered = false
        sticky = false
        leaveWork?.cancel(); leaveWork = nil
    }

    func hide(animated: Bool) {
        guard isShown, let panel else { return }
        isShown = false
        sticky = false
        autoHideWork?.cancel(); autoHideWork = nil
        leaveWork?.cancel(); leaveWork = nil
        lineView?.hidePreview()
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.animationBehavior = .none
        let v = ClotheslineView(controller: self)
        p.contentView = v
        lineView = v
        panel = p
        return p
    }
}

// MARK: - Line

/// 绳子 + 卡片。视图翻转（左上原点），与 ClotheslineLayout 一致。
final class ClotheslineView: NSView {

    private weak var controller: ClotheslineController?
    private var cards: [ClotheslineCard] = []
    private let emptyLabel = NSTextField(labelWithString: L("截图后会挂在这里"))
    private var preview: NSPanel?
    private var previewWork: DispatchWorkItem?

    init(controller: ClotheslineController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var style: ClotheslineStyle { controller?.style ?? .default }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, sag = style.sag
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 6, y: ClotheslineLayout.lineY(at: 6, width: w, sag: sag)))
        var x: CGFloat = 6
        while x < w - 6 {
            x = min(x + 8, w - 6)
            path.line(to: NSPoint(x: x, y: ClotheslineLayout.lineY(at: x, width: w, sag: sag)))
        }
        path.lineCapStyle = .round
        let (rope, width, halo): (NSColor, CGFloat, CGFloat) = {
            switch style {
            case .binder:  return (NSColor(calibratedWhite: 0.32, alpha: 1), 1.4, 3.5)        // 钢丝
            case .plastic: return (NSColor(calibratedWhite: 0.70, alpha: 1), 1.8, 3.4)        // 白色塑料绳
            default:       return (NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.30, alpha: 1), 1.6, 3.5)  // 麻绳
            }
        }()
        NSColor.white.withAlphaComponent(style == .plastic ? 0.25 : 0.55).setStroke()
        if style == .plastic { NSColor.black.withAlphaComponent(0.18).setStroke() }
        path.lineWidth = halo
        path.stroke()
        rope.setStroke()
        path.lineWidth = width
        path.stroke()
        // 两端：钢丝是小挂钩（圆环），绳子是结
        for kx in [CGFloat(6), w - 6] {
            let ky = ClotheslineLayout.lineY(at: kx, width: w, sag: sag)
            let r = NSRect(x: kx - 3, y: ky - 3, width: 6, height: 6)
            if style == .binder {
                rope.setStroke()
                let ring = NSBezierPath(ovalIn: r); ring.lineWidth = 1.2; ring.stroke()
            } else {
                rope.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
        }
    }

    /// 换样式：卡片全部重建（夹子、留白、倾斜都变了）
    func restyle() {
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        reload(dropping: nil)
        swingAll()
    }

    /// 衣架空白处右键：换样式
    override func menu(for event: NSEvent) -> NSMenu? {
        hidePreview()
        let m = NSMenu()
        let title = NSMenuItem(title: L("衣架样式"), action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        ClotheslineView.addStyleItems(to: m, current: style, target: self)
        return m
    }

    static func addStyleItems(to m: NSMenu, current: ClotheslineStyle, target: AnyObject) {
        for st in ClotheslineStyle.allCases {
            let i = NSMenuItem(title: st.title, action: #selector(ClotheslineView.pickStyle(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = st.rawValue
            i.state = st == current ? .on : .off
            m.addItem(i)
        }
    }

    @objc func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = ClotheslineStyle(rawValue: raw) else { return }
        controller?.onStyleChange?(st)
    }

    /// 按 store 重新摆卡片；dropping = 刚挂上的那张（播放落下 + 摇摆）
    func reload(dropping: String?) {
        guard let controller else { return }
        hidePreview()
        let items = controller.store.ordered
        let frames = ClotheslineLayout.frames(
            aspects: items.map { style.outerAspect($0.pointSize.width / max($0.pointSize.height, 1)) },
            width: bounds.width, sag: style.sag)
        // 复用已有卡片（保留缩略图），删掉不在的
        var old = Dictionary(uniqueKeysWithValues: cards.map { ($0.item.id, $0) })
        cards = zip(items, frames).map { item, f in
            let c = old.removeValue(forKey: item.id) ?? ClotheslineCard(item: item, controller: controller, line: self)
            c.update(item: item, frame: f)
            if c.superview == nil { addSubview(c) }
            return c
        }
        old.values.forEach { $0.removeFromSuperview() }
        emptyLabel.isHidden = !items.isEmpty
        if items.isEmpty {
            emptyLabel.sizeToFit()
            emptyLabel.frame.origin = NSPoint(x: (bounds.width - emptyLabel.frame.width) / 2,
                                              y: ClotheslineLayout.lineY + style.sag + 10)
        }
        needsDisplay = true
        if let dropping, let c = cards.first(where: { $0.item.id == dropping }) { c.drop() }
    }

    func swingAll() { cards.forEach { $0.swing(amplitude: 3) } }

    // MARK: Preview

    func schedulePreview(for card: ClotheslineCard) {
        previewWork?.cancel()
        let w = DispatchWorkItem { [weak self, weak card] in
            guard let self, let card, card.isHovered else { return }
            self.showPreview(for: card)
        }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func hidePreview() {
        previewWork?.cancel(); previewWork = nil
        preview?.orderOut(nil)
    }

    private func showPreview(for card: ClotheslineCard) {
        guard let controller, let window, let screen = window.screen,
              let img = controller.store.thumbnail(card.item, maxPixels: 1200) else { return }
        let pt = card.item.pointSize
        let fit = min(1, 560 / pt.width, 380 / pt.height)
        let size = NSSize(width: max(pt.width * fit, 60), height: max(pt.height * fit, 40))
        let p = preview ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = NSImageView()
            v.imageScaling = .scaleProportionallyUpOrDown
            v.wantsLayer = true
            v.layer?.cornerRadius = 6
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = NSColor.separatorColor.cgColor
            p.contentView = v
            preview = p
            return p
        }()
        (p.contentView as? NSImageView)?.image = NSImage(cgImage: img, size: size)
        let cardOnScreen = window.convertToScreen(card.convert(card.bounds, to: nil))
        var x = cardOnScreen.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        let y = max(cardOnScreen.minY - 12 - size.height, screen.visibleFrame.minY + 8)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
    }
}

// MARK: - Card

/// 一张挂着的截图：相框 + 木夹子，绕夹子轻轻摇摆。
final class ClotheslineCard: NSView, NSDraggingSource {

    private(set) var item: ClotheslineStore.Item
    private weak var controller: ClotheslineController?
    private weak var line: ClotheslineView?
    private let body = CALayer()
    private let photo = CALayer()
    /// 夹子 / 胶带：按样式重画
    private let fastener = CALayer()
    /// 拍立得下边的时间
    private let caption = CATextLayer()
    private let closeButton = NSButton()
    private var downPoint: NSPoint?
    private var dragStarted = false
    private(set) var isHovered = false

    /// 卡片四周给摇摆和夹子留的空间
    private static let pad = NSEdgeInsets(top: 14, left: 8, bottom: 8, right: 8)

    init(item: ClotheslineStore.Item, controller: ClotheslineController, line: ClotheslineView) {
        self.item = item
        self.controller = controller
        self.line = line
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.28
        body.shadowRadius = 3
        body.shadowOffset = CGSize(width: 0, height: -2)
        body.cornerRadius = 2
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        caption.fontSize = 9
        caption.alignmentMode = .center
        caption.contentsScale = 2
        caption.foregroundColor = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor
        body.addSublayer(photo)
        body.addSublayer(caption)
        body.addSublayer(fastener)
        layer?.addSublayer(body)
        for l in [body, photo, fastener, caption] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull()]
        }
        photo.contents = controller.store.thumbnail(item)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("删除"))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(deleteItem)
        closeButton.toolTip = L("从衣架上取下")
        closeButton.isHidden = true
        addSubview(closeButton)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// cardFrame：卡片本身在衣架里的位置（左上原点）
    func update(item: ClotheslineStore.Item, frame cardFrame: CGRect) {
        self.item = item
        let p = ClotheslineCard.pad
        frame = NSRect(x: cardFrame.minX - p.left, y: cardFrame.minY - p.top,
                       width: cardFrame.width + p.left + p.right, height: cardFrame.height + p.top + p.bottom)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let style = controller?.style ?? .default
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 本视图不翻转：层坐标左下原点
        let bodyRect = CGRect(x: p.left, y: p.bottom, width: cardFrame.width, height: cardFrame.height)
        body.bounds = CGRect(origin: .zero, size: bodyRect.size)
        body.anchorPoint = CGPoint(x: 0.5, y: 1)                    // 绕夹子摆
        body.position = CGPoint(x: bodyRect.midX, y: bodyRect.maxY)
        body.backgroundColor = (dark ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor.white).cgColor
        body.cornerRadius = style.cornerRadius
        body.transform = CATransform3DMakeRotation(restAngle, 0, 0, 1)
        let m = style.mat
        photo.frame = CGRect(x: m.side, y: m.bottom, width: bodyRect.width - m.side * 2,
                             height: bodyRect.height - m.top - m.bottom)
        photo.cornerRadius = style == .plastic ? 4 : 0
        caption.isHidden = !style.showsTime
        if style.showsTime {
            let f = DateFormatter()
            f.dateFormat = bodyRect.width < 72 ? "HH:mm" : "MM-dd HH:mm"     // 窄卡片只写时间
            caption.string = f.string(from: item.created)
            caption.frame = CGRect(x: 0, y: 3, width: bodyRect.width, height: 12)
        }
        ClotheslineCard.drawFastener(fastener, style: style, item: item, cardSize: bodyRect.size)
        CATransaction.commit()
        closeButton.frame = NSRect(x: bounds.width - p.right - 10, y: bounds.height - p.top - 8, width: 16, height: 16)
    }

    /// 静止时的歪斜角度：按 id 固定在 ±maxTilt° 之间
    private var restAngle: CGFloat {
        let h = item.id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let tilt = (controller?.style ?? .default).maxTilt
        return (CGFloat(h % 41) - 20) / 20 * tilt * .pi / 180
    }

    /// 夹子 / 胶带，画在卡片顶端正中，往上伸到绳子（卡片层坐标：左下原点，顶边 y = h）
    static func drawFastener(_ f: CALayer, style: ClotheslineStyle, item: ClotheslineStore.Item, cardSize: CGSize) {
        f.sublayers?.forEach { $0.removeFromSuperlayer() }
        f.frame = CGRect(origin: .zero, size: cardSize)
        let w = cardSize.width, h = cardSize.height, cx = w / 2
        let up = ClotheslineLayout.clipDrop            // 卡片顶到绳子的距离
        let gray = NSColor(calibratedRed: 0.37, green: 0.37, blue: 0.35, alpha: 1)
        @discardableResult func rect(_ r: CGRect, _ color: NSColor, radius: CGFloat = 0) -> CALayer {
            let l = CALayer()
            l.frame = r
            l.backgroundColor = color.cgColor
            l.cornerRadius = radius
            f.addSublayer(l)
            return l
        }
        let (cr, cg, cb) = ClotheslineStyle.candy[ClotheslineStyle.candyIndex(item.id)]
        switch style.fastener {
        case .woodClip:
            let wood = NSColor(calibratedRed: 0.75, green: 0.54, blue: 0.36, alpha: 1)
            let clip = rect(CGRect(x: cx - 4.5, y: h - 18 + up + 2, width: 9, height: 18), item.pinned ? gray : wood, radius: 2)
            let stripe = CALayer()
            stripe.frame = CGRect(x: 4, y: 2, width: 1, height: 14)
            stripe.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.25).cgColor
            clip.addSublayer(stripe)
        case .binderClip:
            // 两根钢丝把手 + 黑色夹身；固定的用黄铜色
            let wire = CAShapeLayer()
            let path = CGMutablePath()
            // 把手从夹身两侧伸到绳子上方再收拢，像真的长尾夹
            path.move(to: CGPoint(x: cx - 8, y: h + 3)); path.addLine(to: CGPoint(x: cx - 4, y: h + up + 4))
            path.addLine(to: CGPoint(x: cx + 4, y: h + up + 4)); path.addLine(to: CGPoint(x: cx + 8, y: h + 3))
            wire.path = path
            wire.strokeColor = NSColor(calibratedWhite: 0.38, alpha: 1).cgColor
            wire.lineWidth = 1.6
            wire.lineJoin = .round
            wire.lineCap = .round
            wire.fillColor = nil
            f.addSublayer(wire)
            let brass = NSColor(calibratedRed: 0.73, green: 0.46, blue: 0.09, alpha: 1)
            rect(CGRect(x: cx - 11, y: h - 7, width: 22, height: 11),
                 item.pinned ? brass : NSColor(calibratedWhite: 0.16, alpha: 1), radius: 1.5)
        case .plasticClip:
            let color = item.pinned ? gray : NSColor(calibratedRed: cr, green: cg, blue: cb, alpha: 1)
            let clip = rect(CGRect(x: cx - 5, y: h - 20 + up + 2, width: 10, height: 20), color, radius: 4)
            let hole = CALayer()
            hole.frame = CGRect(x: 3, y: 11, width: 4, height: 4)
            hole.cornerRadius = 2
            hole.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.55).cgColor
            clip.addSublayer(hole)
        case .tape:
            let color = item.pinned ? gray.withAlphaComponent(0.8)
                : NSColor(calibratedRed: cr, green: cg, blue: cb, alpha: 0.78)
            let tape = rect(CGRect(x: cx - 16, y: h - 8, width: 32, height: up + 10), color)
            let tilt = (CGFloat(ClotheslineStyle.candyIndex(item.id + "t")) - 2) * 3 * .pi / 180
            tape.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        }
    }

    // MARK: Animation

    func swing(amplitude degrees: CGFloat) {
        let r = restAngle, a = degrees * .pi / 180
        let anim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        anim.values = [r + a, r - a * 0.7, r + a * 0.45, r - a * 0.25, r + a * 0.1, r]
        anim.duration = 0.9
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        body.add(anim, forKey: "swing")
    }

    /// 新挂上：从上方落下，再摆几下
    func drop() {
        let fall = CABasicAnimation(keyPath: "transform.translation.y")
        fall.fromValue = 40
        fall.toValue = 0
        fall.duration = 0.25
        fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
        body.add(fall, forKey: "drop")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        body.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.swing(amplitude: 9) }
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        closeButton.isHidden = false
        line?.schedulePreview(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeButton.isHidden = true
        line?.hidePreview()
    }

    override func mouseDown(with e: NSEvent) {
        downPoint = e.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard !dragStarted, let d = downPoint, hypot(e.locationInWindow.x - d.x, e.locationInWindow.y - d.y) > 3,
              let controller, let url = ClotheslineActions.dragFile(item, store: controller.store) else { return }
        dragStarted = true
        line?.hidePreview()
        controller.dragging = true
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        let img = photo.contents.map { NSImage(cgImage: $0 as! CGImage, size: body.bounds.size) }
        dragItem.setDraggingFrame(NSRect(origin: NSPoint(x: ClotheslineCard.pad.left, y: ClotheslineCard.pad.bottom),
                                         size: body.bounds.size), contents: img)
        beginDraggingSession(with: [dragItem], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        defer { downPoint = nil }
        guard !dragStarted, let controller else { return }
        if e.clickCount >= 2 {
            ClotheslineActions.openInPreview(item, store: controller.store)
        } else {
            ClotheslineActions.copy(item, store: controller.store)
            swing(amplitude: 4)
        }
    }

    // 拖到 App = 发一份；拖到 Finder = 存一份（只给复制，Finder 不会把衣架里的文件搬走）
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        controller?.dragging = false
        Log.write("clothesline: dragged out (\(operation.isEmpty ? "cancelled" : "copied"))")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        line?.hidePreview()
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        add(L("复制"), #selector(copyItem))
        add(L("用「预览」打开"), #selector(openItem))
        add(L("存到桌面"), #selector(saveItem))
        add(L("钉在屏幕上"), #selector(pinItem))
        add(L("识别文字"), #selector(ocrItem))
        m.addItem(.separator())
        add(item.pinned ? L("取消固定") : L("固定在衣架上"), #selector(togglePin))
        add(L("从衣架上取下"), #selector(deleteItem))
        m.addItem(.separator())
        if let line {
            let sub = NSMenu()
            ClotheslineView.addStyleItems(to: sub, current: controller?.style ?? .default, target: line)
            let i = NSMenuItem(title: L("衣架样式"), action: nil, keyEquivalent: "")
            i.submenu = sub
            m.addItem(i)
        }
        return m
    }

    @objc private func copyItem() { if let s = controller?.store { ClotheslineActions.copy(item, store: s) } }
    @objc private func openItem() { if let s = controller?.store { ClotheslineActions.openInPreview(item, store: s) } }
    @objc private func saveItem() { if let s = controller?.store { ClotheslineActions.saveToDesktop(item, store: s) } }
    @objc private func pinItem() {
        guard let s = controller?.store, let img = s.image(item) else { return }
        controller?.hide(animated: true)
        PinnedImages.shared.pin(img, scale: CGFloat(item.scale))
    }
    @objc private func ocrItem() {
        guard let img = controller?.store.image(item) else { return }
        TextRecognition.copyText(in: img)
    }
    @objc private func togglePin() {
        controller?.store.setPinned(item.id, !item.pinned)
        controller?.reload()
    }
    @objc private func deleteItem() {
        controller?.store.remove(item.id)
        controller?.reload()
    }
}

/// 卡片上的动作（复制 / 预览 / 存桌面 / 拖出用的文件）
enum ClotheslineActions {

    static func copy(_ item: ClotheslineStore.Item, store: ClotheslineStore) {
        guard let png = try? Data(contentsOf: store.url(item)), let img = store.image(item) else { return }
        Capture.copyToPasteboard(img, png: png, scale: CGFloat(item.scale))
        HUD.shared.show(L("已复制"), duration: 0.7)
    }

    static func openInPreview(_ item: ClotheslineStore.Item, store: ClotheslineStore) {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"),
              let url = dragFile(item, store: store) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
    }

    static func saveToDesktop(_ item: ClotheslineStore.Item, store: ClotheslineStore) {
        guard let png = try? Data(contentsOf: store.url(item)) else { return }
        if Capture.saveToDesktop(png, date: item.created) != nil { HUD.shared.show(L("已存到桌面"), duration: 0.8) }
    }

    /// 拖出 / 预览用的副本：起个好认的名字（「截图 日期 时间.png」），放在衣架文件夹的 Drag/<id>/
    static func dragFile(_ item: ClotheslineStore.Item, store: ClotheslineStore) -> URL? {
        let dir = store.dragDir(item)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Capture.fileName(item.created))
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.copyItem(at: store.url(item), to: url) } catch { return nil }
        }
        return url
    }
}

/// 设置页「截图」卡片里的两个按钮
enum ClotheslineSettings {
    static func openFolder() {
        let dir = ClotheslineController.shared.store.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    static func clearAll() {
        let store = ClotheslineController.shared.store
        let a = NSAlert()
        a.messageText = L("清空衣架上的 %d 张截图？", store.items.count)
        a.informativeText = L("包括固定的。删除后无法恢复。")
        a.addButton(withTitle: L("清空"))
        a.addButton(withTitle: L("取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.removeAll()
        ClotheslineController.shared.reload()
        Log.write("clothesline: cleared")
    }
}

/// `--clothesline-demo`：挂几张不同比例的示例图，用来看衣架的样子
enum ClotheslineDemo {
    static func seed(_ store: ClotheslineStore) {
        let shapes: [(Int, Int, NSColor)] = [(800, 500, .systemBlue), (600, 600, .systemOrange), (400, 700, .systemTeal),
                                             (1200, 500, .systemPurple), (700, 450, .systemGreen), (900, 600, .systemPink)]
        for (i, (w, h, color)) in shapes.enumerated() {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.fill(CGRect(x: w / 10, y: h / 2, width: w * 6 / 10, height: h / 12))
            ctx.fill(CGRect(x: w / 10, y: h / 3, width: w * 4 / 10, height: h / 12))
            guard let img = ctx.makeImage(), let png = Capture.png(img, scale: 2) else { continue }
            let item = store.add(png: png, pixelWidth: w, pixelHeight: h, scale: 2, date: Date() + Double(i))
            if i == 0, let item { store.setPinned(item.id, true) }
        }
    }
}
