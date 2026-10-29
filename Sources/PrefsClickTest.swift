import Cocoa
import ApplicationServices
import SwiftUI

/// `--ui-click-test`: clicks every sidebar page and every device sub-tab of the real
/// settings window with real mouse events, and checks the page actually switched.
///
/// Each item is clicked ONCE, in its blank area (near the right edge of the row, away
/// from the icon and text), with a few points of hand jitter between down and up —
/// the clicks users reported needing several tries for. Round 2 first sends the window
/// to the background (another app in front) so the first click also has to land.
///
/// Runs on a background thread (clicks are real events the main thread must process);
/// the model and the reported layout are read on the main thread. The cursor is put back afterwards.
/// Exit code = number of failed clicks.
enum PrefsClickTest {

    static func run(model: PrefModel, done: @escaping (Int) -> Void) {
        Thread.detachNewThread {
            let home = CGEvent(source: nil)?.location ?? .zero
            var failures = 0
            func log(_ s: String) { print(s); Log.write("ui-click-test: " + s) }

            for round in 1...2 {
                log(round == 1 ? "— 第 1 轮：窗口在前台" : "— 第 2 轮：每次点击前先把窗口切到后台")
                for page in PrefPage.allCases {
                    // Start from another page, so a click that hit the wrong row can't pass by luck
                    _ = onMain { model.page = page == .general ? .normalMouse : .general }
                    usleep(150_000)
                    if round == 2 { sendWindowToBack(); verifyInactive() }
                    // Right end of the highlighted 280pt row (sidebar starts 12pt into the window)
                    let ok = clickAndCheck(label: page.title, at: { f, win in
                        CGPoint(x: win.minX + 12 + UI.sidebarW - 24, y: f.midY) }) {
                        onMain { model.page == page } ?? false
                    }
                    log("\(ok ? "PASS" : "FAIL")  侧栏「\(page.title)」")
                    if !ok { failures += 1 }
                }
                _ = onMain { model.page = .normalMouse }
                usleep(300_000)
                var tabRowX: CGFloat?
                for (i, tab) in [L("按键识别"), L("手势设置")].enumerated() {
                    _ = onMain { model.subTab = i == 0 ? 1 : 0 }
                    usleep(150_000)
                    if round == 2 { sendWindowToBack(); verifyInactive() }
                    // Inside the pill's own 14pt side padding (not on the text)
                    let ok = clickAndCheck(label: tab, at: { f, _ in CGPoint(x: f.maxX - 5, y: f.midY) }) {
                        onMain { model.subTab == i } ?? false
                    }
                    log("\(ok ? "PASS" : "FAIL")  页签「\(tab)」")
                    if !ok { failures += 1 }
                    // The tab row must not move when the selection changes
                    let x = frameOfControl(L("按键识别"))?.control.minX
                    if let x0 = tabRowX, let x, abs(x - x0) > 1 {
                        log("FAIL  页签位置跳动 \(Int(x0)) → \(Int(x))"); failures += 1
                    }
                    tabRowX = tabRowX ?? x
                }
            }
            CGWarpMouseCursorPosition(home)
            log(failures == 0 ? "ALL CLICKS LANDED" : "\(failures) 次点击没有生效")
            DispatchQueue.main.async { done(failures) }
        }
    }

    /// Find the control by its accessibility label, click once at `at(control, window)`
    /// — a blank spot of the visible row / pill — then give the UI a moment and
    /// evaluate `check`. (AX reports only the icon+text as the control's frame.)
    private static func clickAndCheck(label: String, at: (CGRect, CGRect) -> CGPoint,
                                      check: () -> Bool) -> Bool {
        guard let (frame, win) = frameOfControl(label) else {
            let wins = onMain { NSApp.windows.filter(\.isVisible).map { "\($0.title)@\(Int($0.frame.minX)),\(Int($0.frame.minY))" } } ?? []
            Log.write("ui-click-test:       找不到控件「\(label)」 可见窗口=\(wins)")
            return false
        }
        let p = at(frame, win)
        let owner = topWindowOwner(at: p)
        Log.write("ui-click-test:       「\(label)」frame=\(frame.integral) 点击=\(p) 最上层窗口 pid \(owner.map { String($0) } ?? "?")")
        if let owner, owner != getpid() {
            print("      点击点被别的窗口盖住，跳过（不算 GestureKit 的问题）")
            return true
        }
        click(at: p)
        for _ in 0..<10 {
            usleep(60_000)
            if check() { return true }
        }
        return false
    }

    private static func click(at p: CGPoint) {
        func post(_ type: CGEventType, _ at: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.mouseMoved, p)
        usleep(80_000)
        post(.leftMouseDown, p)
        usleep(40_000)
        let jitter = CGPoint(x: p.x + 3, y: p.y + 2)          // a real hand never holds perfectly still
        post(.leftMouseDragged, jitter)
        usleep(40_000)
        post(.leftMouseUp, jitter)
    }

    /// Run on the main thread, but give up after 3 s: a click that started a modal
    /// tracking loop (e.g. a window drag) stops the main queue, and the test must
    /// report that instead of hanging.
    private static func onMain<T>(_ block: @escaping () -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var out: T?
        DispatchQueue.main.async { out = block(); sem.signal() }
        if sem.wait(timeout: .now() + 3) == .timedOut {
            print("      主线程 3 秒没响应（被拖动/模态循环占住）")
            return nil
        }
        return out
    }

    /// pid of the frontmost normal window under `p` (CG coordinates).
    private static func topWindowOwner(at p: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.contains(p) { return w[kCGWindowOwnerPID as String] as? pid_t }
        }
        return nil
    }

    private static func verifyInactive() {
        if onMain({ NSApp.isActive }) == true { print("      （注意：未能切到后台）") }
    }

    /// Make our app inactive so the window is not key.
    private static func sendWindowToBack() {
        // Deactivate only: the window stays where it is (visible) but is no longer key,
        // the state the settings window is in after the user worked in another app.
        _ = onMain { NSApp.deactivate() }
        usleep(500_000)
    }

    // MARK: - AX lookup (CG global coordinates, top-left origin)

    /// Control frame in CG screen coordinates, from the layout the settings window
    /// reported (`ClickTargets`), plus the window frame. (AX queries into our own
    /// process proved unreliable on macOS 27: kAXWindows came back as the app element.)
    private static func frameOfControl(_ label: String) -> (control: CGRect, window: CGRect)? {
        onMain { () -> (CGRect, CGRect)? in
            guard let local = ClickTargets.frames[label],
                  let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView is FirstClickHostingView<PreferencesView> }),
                  let host = win.contentView,
                  let mainH = NSScreen.screens.first?.frame.maxY else { return nil }
            // `local` is in the root view's space = the hosting view's bounds (flipped, top-left).
            // Let AppKit do view → window → screen, so title bar height etc. never matter.
            let toCG = { (r: CGRect) -> CGRect in
                let flipped = host.isFlipped ? r : CGRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height)
                let s = win.convertToScreen(host.convert(flipped, to: nil))       // Cocoa, bottom-left origin
                return CGRect(x: s.minX, y: mainH - s.maxY, width: s.width, height: s.height)
            }
            let wf = CGRect(x: win.frame.minX, y: mainH - win.frame.maxY, width: win.frame.width, height: win.frame.height)
            return (toCG(local), wf)
        } ?? nil
    }
}

/// Where the settings window laid out its clickable rows and tabs (window-content
/// coordinates, top-left origin). Only recorded while `--ui-click-test` runs.
enum ClickTargets {
    static let enabled = CommandLine.arguments.contains("--ui-click-test")
    static var frames: [String: CGRect] = [:]
    /// Coordinate space set on PreferencesView's root (= the hosting view's bounds).
    static let space = "prefsRoot"
}

extension View {
    /// `--ui-click-test`: report this control's frame under `label`; no-op otherwise.
    @ViewBuilder func clickTarget(_ label: String) -> some View {
        if ClickTargets.enabled {
            background(GeometryReader { g in
                Color.clear
                    .onAppear { ClickTargets.frames[label] = g.frame(in: .named(ClickTargets.space)) }
                    .onChange(of: g.frame(in: .named(ClickTargets.space))) { ClickTargets.frames[label] = $0 }
            })
        } else {
            self
        }
    }
}
