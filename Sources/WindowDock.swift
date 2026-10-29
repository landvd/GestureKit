import Cocoa
import ApplicationServices

/// 窗口吸附 (docs/RE_MODULES.md §7): a window parked at the left/right screen
/// edge, leaving a 1px sliver; touching that edge slides it back in.
///
/// Sources of docking: preset actions `window/dockLeft|dockRight`, or (opt-in,
/// `Config.windowDock`) dragging a window onto an outer screen edge.
/// All coordinates are Cocoa (bottom-left origin). The engine forwards mouse
/// events here *after* passing them on; AX work runs asynchronously so the
/// event tap never waits on another app.
final class WindowDock {

    enum Side: String { case left, right }

    static let sliver: CGFloat = 1            // RE: 留边 1 px
    static let minWindowSize: CGFloat = 50    // RE: 过滤 < 50×50 的窗口
    static let edgeBand: CGFloat = 2          // cursor counts as "at the edge" within this
    static let leaveMargin: CGFloat = 30      // revealed window re-hides once the cursor is this far out
    static let dragThreshold: CGFloat = 20    // window must have moved this much to count as dragged

    struct Docked {
        let window: AnyObject
        let side: Side
        let screen: CGRect
        var frame: CGRect                     // last frame we set
        var revealed: Bool
    }

    let driver: DockDriver
    /// false in selftest: run AX work inline, no animation.
    var runAsync = true
    /// Dock on drag-to-edge (the preset actions work regardless).
    var autoDock = false

    private(set) var docked: [Docked] = []
    private var dragStart: (window: AnyObject, frame: CGRect)?
    private var buttonDown = false
    private var busy = false                  // an animation is running

    init(driver: DockDriver = AXDockDriver()) { self.driver = driver }

    // MARK: - Geometry (pure)

    static func hiddenFrame(_ f: CGRect, side: Side, screen: CGRect) -> CGRect {
        var r = f
        r.origin.x = side == .left ? screen.minX - f.width + sliver : screen.maxX - sliver
        return r
    }

    static func shownFrame(_ f: CGRect, side: Side, screen: CGRect) -> CGRect {
        var r = f
        r.origin.x = side == .left ? screen.minX : screen.maxX - f.width
        return r
    }

    /// Which outer screen edge `p` touches. Edges shared with a neighbouring
    /// screen don't count: the cursor would just cross over.
    static func edge(at p: CGPoint, screens: [CGRect]) -> (side: Side, screen: CGRect)? {
        guard let s = screens.first(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) else { return nil }
        func shared(_ x: CGFloat) -> Bool {
            screens.contains { o in
                o != s && (abs(o.maxX - x) <= 1 || abs(o.minX - x) <= 1) && o.minY < s.maxY && o.maxY > s.minY
            }
        }
        if p.x <= s.minX + edgeBand, !shared(s.minX) { return (.left, s) }
        if p.x >= s.maxX - edgeBand, !shared(s.maxX) { return (.right, s) }
        return nil
    }

    // MARK: - Events from the engine (Cocoa points)

    func mouseDown(at p: CGPoint) {
        buttonDown = true
        guard autoDock || !docked.isEmpty else { return }
        perform { [self] in
            guard let w = driver.window(at: p), let f = driver.frame(of: w) else { dragStart = nil; return }
            dragStart = (w, f)
        }
    }

    func mouseUp(at p: CGPoint) {
        buttonDown = false
        let start = dragStart
        dragStart = nil
        guard let start else { return }
        perform { [self] in
            guard let now = driver.frame(of: start.window),
                  hypot(now.minX - start.frame.minX, now.minY - start.frame.minY) >= WindowDock.dragThreshold
            else { return }
            // Dragging a docked window away from its edge undocks it.
            if let i = index(of: start.window) { docked.remove(at: i) }
            if autoDock, let e = WindowDock.edge(at: p, screens: driver.screens) {
                dock(start.window, side: e.side, screen: e.screen, frame: now)
            }
        }
    }

    func mouseMoved(to p: CGPoint) {
        guard !docked.isEmpty, !busy, !buttonDown else { return }
        for (i, d) in docked.enumerated() {
            if !d.revealed {
                guard let e = WindowDock.edge(at: p, screens: [d.screen]), e.side == d.side,
                      p.y >= d.frame.minY, p.y <= d.frame.maxY else { continue }
                reveal(i)
                return
            }
            if !d.frame.insetBy(dx: -WindowDock.leaveMargin, dy: -WindowDock.leaveMargin).contains(p) {
                hide(i)
                return
            }
        }
    }

    // MARK: - Actions

    /// Preset 「吸附到左/右边」: park the focused window.
    func dockFocused(_ side: Side) {
        perform { [self] in
            guard let w = driver.focusedWindow(), let f = driver.frame(of: w) else { return }
            let screen = driver.screens.max { a, b in
                a.intersection(f).width * a.intersection(f).height < b.intersection(f).width * b.intersection(f).height
            } ?? f
            if let i = index(of: w) { docked.remove(at: i) }
            dock(w, side: side, screen: screen, frame: f)
        }
    }

    /// Bring every parked window back (quit, feature switched off).
    func revealAll() {
        for d in docked {
            driver.setFrame(d.window, WindowDock.shownFrame(d.frame, side: d.side, screen: d.screen))
        }
        docked = []
    }

    // MARK: - Private

    private func dock(_ w: AnyObject, side: Side, screen: CGRect, frame f: CGRect) {
        guard f.width >= WindowDock.minWindowSize, f.height >= WindowDock.minWindowSize else { return }
        let hidden = WindowDock.hiddenFrame(f, side: side, screen: screen)
        docked.append(Docked(window: w, side: side, screen: screen, frame: hidden, revealed: false))
        slide(w, from: f, to: hidden) { [weak self] in
            guard let self else { return }
            // Some apps refuse to go (mostly) off-screen; don't track those.
            if let got = self.driver.frame(of: w), abs(got.minX - hidden.minX) > 4, let i = self.index(of: w) {
                Log.write("window dock: app kept its window on screen, not docked")
                self.docked.remove(at: i)
            }
        }
    }

    private func reveal(_ i: Int) {
        var d = docked[i]
        let shown = WindowDock.shownFrame(d.frame, side: d.side, screen: d.screen)
        let from = d.frame
        d.frame = shown
        d.revealed = true
        docked[i] = d
        driver.activate(d.window)
        slide(d.window, from: from, to: shown)
    }

    private func hide(_ i: Int) {
        var d = docked[i]
        let hidden = WindowDock.hiddenFrame(d.frame, side: d.side, screen: d.screen)
        let from = d.frame
        d.frame = hidden
        d.revealed = false
        docked[i] = d
        slide(d.window, from: from, to: hidden)
    }

    private func index(of w: AnyObject) -> Int? {
        docked.firstIndex { driver.same($0.window, w) }
    }

    private func perform(_ work: @escaping () -> Void) {
        if runAsync { DispatchQueue.main.async(execute: work) } else { work() }
    }

    /// ~0.15 s slide in 8 steps (position only; size is untouched).
    private func slide(_ w: AnyObject, from: CGRect, to: CGRect, done: (() -> Void)? = nil) {
        guard runAsync else { driver.setFrame(w, to); done?(); return }
        busy = true
        let steps = 8
        for k in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.018 * Double(k)) { [weak self] in
                let t = CGFloat(k) / CGFloat(steps)
                let e = 1 - (1 - t) * (1 - t)                 // ease-out
                var r = to
                r.origin.x = from.minX + (to.minX - from.minX) * e
                self?.driver.setFrame(w, r)
                if k == steps { self?.busy = false; done?() }
            }
        }
    }
}

// MARK: - Window access

protocol DockDriver: AnyObject {
    var screens: [CGRect] { get }                       // NSScreen frames, Cocoa coords
    func window(at p: CGPoint) -> AnyObject?
    func focusedWindow() -> AnyObject?
    func frame(of w: AnyObject) -> CGRect?
    func setFrame(_ w: AnyObject, _ r: CGRect)          // moves only (keeps size)
    func activate(_ w: AnyObject)
    func same(_ a: AnyObject, _ b: AnyObject) -> Bool
}

/// Accessibility-backed driver.
final class AXDockDriver: DockDriver {

    private var mainHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    var screens: [CGRect] { NSScreen.screens.map(\.frame) }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func ax(_ w: AnyObject) -> AXUIElement { unsafeBitCast(w, to: AXUIElement.self) }

    func window(at p: CGPoint) -> AnyObject? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x),
                                               Float(mainHeight - p.y), &el) == .success, let el else { return nil }
        if (attr(el, kAXRoleAttribute as String) as? String) == kAXWindowRole as String { return el }
        return attr(el, kAXWindowAttribute as String)
    }

    func focusedWindow() -> AnyObject? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return attr(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute as String)
    }

    func frame(of w: AnyObject) -> CGRect? {
        guard let pv = attr(ax(w), kAXPositionAttribute as String),
              let sv = attr(ax(w), kAXSizeAttribute as String) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return WindowLayout.fromAX(CGRect(origin: p, size: s), mainHeight: mainHeight)
    }

    func setFrame(_ w: AnyObject, _ r: CGRect) {
        var p = WindowLayout.toAX(r, mainHeight: mainHeight).origin
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(ax(w), kAXPositionAttribute as CFString, v)
        }
    }

    func activate(_ w: AnyObject) {
        var pid: pid_t = 0
        if AXUIElementGetPid(ax(w), &pid) == .success {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementSetAttributeValue(ax(w), kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax(w), kAXRaiseAction as CFString)
    }

    func same(_ a: AnyObject, _ b: AnyObject) -> Bool { CFEqual(a, b) }
}
