import Cocoa

/// Window layout math on integer screen dimensions with integer division,
/// so odd sizes round down.
enum WindowLayout {

    enum Op: String, CaseIterable {
        case halfLeft, halfRight, halfTop, halfBottom
        case quarterTopLeft, quarterTopRight, quarterBottomLeft, quarterBottomRight
        case center, maximize, maximizeWidth, maximizeHeight
        case nextScreen, previousScreen
    }

    /// Integer-truncated half, matching the original's `(int)w / 2`.
    static func half(_ v: CGFloat) -> CGFloat { CGFloat(Int(v) / 2) }

    /// Target frame for `op` inside a screen's `visibleFrame`
    /// (already excludes menu bar and Dock).
    static func frame(for op: Op, in visible: CGRect) -> CGRect {
        let w = visible.width, h = visible.height
        let halfW = half(w), halfH = half(h)

        switch op {
        case .halfLeft:
            return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: h)
        case .halfRight:
            return CGRect(x: visible.minX + halfW, y: visible.minY, width: halfW, height: h)
        case .halfTop:      // 上半部分（Cocoa y 向上）
            return CGRect(x: visible.minX, y: visible.minY + h - halfH, width: w, height: halfH)
        case .halfBottom:   // 下半部分
            return CGRect(x: visible.minX, y: visible.minY, width: w, height: halfH)
        case .quarterTopLeft:
            return CGRect(x: visible.minX, y: visible.minY + h - halfH, width: halfW, height: halfH)
        case .quarterTopRight:
            return CGRect(x: visible.minX + halfW, y: visible.minY + h - halfH,
                          width: halfW, height: halfH)
        case .quarterBottomLeft:
            return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: halfH)
        case .quarterBottomRight:
            return CGRect(x: visible.minX + halfW, y: visible.minY, width: halfW, height: halfH)
        case .center:
            return CGRect(x: visible.minX, y: visible.minY, width: w, height: h)
        case .maximize:
            return visible
        case .maximizeWidth:
            return CGRect(x: visible.minX, y: visible.minY, width: w, height: h)
        case .maximizeHeight:
            return CGRect(x: visible.minX, y: visible.minY, width: w, height: h)
        case .nextScreen, .previousScreen:
            return visible
        }
    }

    /// Ops that depend on the window's current frame (Cocoa coords);
    /// everything else falls through to `frame(for:in:)`.
    static func frame(for op: Op, in visible: CGRect, current: CGRect) -> CGRect {
        switch op {
        case .center:
            let w = min(current.width, visible.width), h = min(current.height, visible.height)
            return CGRect(x: visible.minX + half(visible.width - w), y: visible.minY + half(visible.height - h),
                          width: w, height: h)
        case .maximizeWidth:
            let h = min(current.height, visible.height)
            let y = max(visible.minY, min(current.minY, visible.maxY - h))
            return CGRect(x: visible.minX, y: y, width: visible.width, height: h)
        case .maximizeHeight:
            let w = min(current.width, visible.width)
            let x = max(visible.minX, min(current.minX, visible.maxX - w))
            return CGRect(x: x, y: visible.minY, width: w, height: visible.height)
        default:
            return frame(for: op, in: visible)
        }
    }

    /// "Already maximized" check for smart zoom (apps round sizes a little).
    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// AX (top-left origin) → Cocoa (bottom-left origin); inverse of `toAX`.
    static func fromAX(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Move a window of `size` onto the next/previous screen, keeping its
    /// relative position inside the screen it came from.
    static func movedToAdjacentScreen(currentFrame: CGRect, screens: [CGRect],
                                      size: CGSize, forward: Bool) -> CGRect? {
        guard screens.count > 1,
              let idx = screens.firstIndex(where: { $0.intersects(currentFrame) }) else { return nil }
        let next = (idx + (forward ? 1 : screens.count - 1)) % screens.count
        let target = screens[next]
        let w = min(size.width, target.width)
        let h = min(size.height, target.height)
        let x = target.midX - w / 2
        let y = target.midY - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Convert a Cocoa (`NSScreen`, bottom-left origin) rect to the
    /// CG/AX coordinate space (top-left origin of the main display).
    static func toAX(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}
