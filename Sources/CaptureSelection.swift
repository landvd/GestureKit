import CoreGraphics

/// 截图选框的状态机（纯逻辑，不碰 AppKit）。
///
/// 坐标：某一块屏幕内的「点」，左上原点（与翻转后的遮罩视图一致）。
/// 窗口列表按从前到后排列，已换算成本屏坐标。
struct CaptureSelection {

    /// 8 个控制点 + 框内（移动）
    enum Handle: CaseIterable, Equatable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
    }

    enum Phase: Equatable {
        /// 还没有选框：悬停时高亮窗口
        case idle
        /// 正在拖出新选框
        case drawing(start: CGPoint)
        /// 正在拖控制点或移动
        case adjusting(handle: Handle, origin: CGRect, start: CGPoint)
        /// 选框已定，等待确认 / 调整
        case selected
    }

    enum Outcome: Equatable { case none, confirm }

    /// 小于这个距离的拖动当作单击
    static let clickSlop: CGFloat = 4
    /// 控制点的命中半径
    static let handleRadius: CGFloat = 7
    /// 调整后选框最小边长
    static let minSide: CGFloat = 2

    let bounds: CGRect
    let windows: [CGRect]
    private(set) var phase: Phase = .idle
    private(set) var rect: CGRect?
    /// 空闲时鼠标下的窗口（高亮用）
    private(set) var hovered: CGRect?

    init(bounds: CGRect, windows: [CGRect]) {
        self.bounds = bounds
        self.windows = windows.compactMap { w in
            let c = w.intersection(bounds)
            return c.isNull || c.width < 1 || c.height < 1 ? nil : c
        }
    }

    // MARK: - Mouse

    mutating func hover(_ p: CGPoint) {
        guard phase == .idle else { return }
        hovered = windowAt(p)
    }

    mutating func mouseDown(_ p: CGPoint, clickCount: Int) -> Outcome {
        let p = clamp(p)
        if let r = rect, phase == .selected {
            if clickCount >= 2, r.contains(p) { return .confirm }
            if let h = handle(at: p) {
                phase = .adjusting(handle: h, origin: r, start: p)
                return .none
            }
        }
        rect = nil
        phase = .drawing(start: p)
        return .none
    }

    mutating func mouseDragged(_ p: CGPoint) {
        let p = clamp(p)
        switch phase {
        case .drawing(let start):
            if dist(start, p) >= CaptureSelection.clickSlop { rect = CaptureSelection.normalized(start, p) }
        case .adjusting(let h, let origin, let start):
            rect = CaptureSelection.adjust(origin, handle: h, dx: p.x - start.x, dy: p.y - start.y, in: bounds)
        default: break
        }
    }

    mutating func mouseUp(_ p: CGPoint) {
        let p = clamp(p)
        switch phase {
        case .drawing(let start):
            if dist(start, p) < CaptureSelection.clickSlop {
                // 单击：选中鼠标下的窗口，没有则整块屏幕
                rect = windowAt(p) ?? bounds
            } else {
                rect = CaptureSelection.normalized(start, p)
            }
            phase = .selected
            hovered = nil
        case .adjusting:
            phase = .selected
        default: break
        }
    }

    // MARK: - Keyboard

    /// 方向键微移（resize = 按住 ⌥ 时改右下角而不是移动）
    mutating func nudge(dx: CGFloat, dy: CGFloat, resize: Bool = false) {
        guard let r = rect, phase == .selected else { return }
        rect = resize
            ? CaptureSelection.adjust(r, handle: .bottomRight, dx: dx, dy: dy, in: bounds)
            : CaptureSelection.adjust(r, handle: .inside, dx: dx, dy: dy, in: bounds)
    }

    /// Esc：有选框先清掉选框（返回 false），否则退出截图（返回 true）
    mutating func escape() -> Bool {
        guard rect != nil else { return true }
        rect = nil
        phase = .idle
        return false
    }

    // MARK: - Geometry

    func windowAt(_ p: CGPoint) -> CGRect? { windows.first { $0.contains(p) } }

    /// 选框上哪个控制点（含框内）在 p 处
    func handle(at p: CGPoint) -> Handle? {
        guard let r = rect else { return nil }
        for (h, c) in CaptureSelection.handlePoints(r) where dist(c, p) <= CaptureSelection.handleRadius {
            return h
        }
        return r.contains(p) ? .inside : nil
    }

    static func handlePoints(_ r: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    static func normalized(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 按控制点把 r 拖动 (dx, dy)：移动时整体夹在屏内；改大小时越过对边会翻转，并夹在屏内。
    static func adjust(_ r: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        if handle == .inside {
            let x = min(max(r.minX + dx, bounds.minX), bounds.maxX - r.width)
            let y = min(max(r.minY + dy, bounds.minY), bounds.maxY - r.height)
            return CGRect(x: x, y: y, width: r.width, height: r.height)
        }
        var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        switch handle {
        case .topLeft:     x0 += dx; y0 += dy
        case .top:         y0 += dy
        case .topRight:    x1 += dx; y0 += dy
        case .right:       x1 += dx
        case .bottomRight: x1 += dx; y1 += dy
        case .bottom:      y1 += dy
        case .bottomLeft:  x0 += dx; y1 += dy
        case .left:        x0 += dx
        case .inside:      break
        }
        func c(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        x0 = c(x0, bounds.minX, bounds.maxX); x1 = c(x1, bounds.minX, bounds.maxX)
        y0 = c(y0, bounds.minY, bounds.maxY); y1 = c(y1, bounds.minY, bounds.maxY)
        var out = normalized(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))
        out.size.width = max(out.width, minSide)
        out.size.height = max(out.height, minSide)
        return out
    }

    /// 工具条放哪：选框下方右对齐；下面放不下放上方；都放不下放框内右下角。始终在屏内。
    static func toolbarFrame(for r: CGRect, size: CGSize, in bounds: CGRect, gap: CGFloat = 6) -> CGRect {
        var x = r.maxX - size.width
        var y = r.maxY + gap
        if y + size.height > bounds.maxY {
            y = r.minY - gap - size.height
            if y < bounds.minY { y = r.maxY - gap - size.height }
        }
        x = min(max(x, bounds.minX), bounds.maxX - size.width)
        y = min(max(y, bounds.minY), bounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 尺寸标签放哪：选框左上角外侧；上面放不下放框内
    static func sizeLabelOrigin(for r: CGRect, size: CGSize, in bounds: CGRect, gap: CGFloat = 4) -> CGPoint {
        var y = r.minY - gap - size.height
        if y < bounds.minY { y = r.minY + gap }
        let x = min(max(r.minX, bounds.minX), bounds.maxX - size.width)
        return CGPoint(x: x, y: y)
    }

    /// 选框（点）→ 定格图里的像素区域：取整、夹在图内。
    static func pixelRect(_ r: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            .integral
        return px.intersection(CGRect(origin: .zero, size: imageSize))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
