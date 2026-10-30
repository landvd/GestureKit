import Cocoa
import ApplicationServices
import Carbon

final class Actions {

    static let shared = Actions()

    /// When true, actions are logged instead of executed (used by --selftest).
    static var dryRun = false
    /// Optional hook used by tests to observe dispatched actions.
    static var observer: ((ActionSpec) -> Void)?
    /// Written to `eventSourceUserData` of every event we synthesize; the
    /// engine passes such events straight through (see GestureEngine.handle).
    static let syntheticMarker: Int64 = 0x474B_5353          // "GKSS"
    /// Events we posted ourselves (shortcuts, clicks, replayed right click): never re-process.
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticMarker
    }
    /// Posted for 「GestureKit 设置」; AppDelegate opens the window.
    static let openPreferencesNotification = Notification.Name("GestureKit.openPreferences")


    /// Visual feedback (HUD), installed by AppDelegate; runs in dry-run too.
    static var presenter: ((ActionSpec) -> Void)?
    /// HUD text after a level change ("音量 64%"); installed by AppDelegate.
    static var levelPresenter: ((String) -> Void)?
    static func levelText(_ text: String) {
        guard let p = levelPresenter else { return }
        DispatchQueue.main.async { p(text) }
    }

    /// Every side effect goes through here (see ActionEffects below). The
    /// selftest swaps in a recorder to assert what an action would really do.
    var effects: ActionEffects = SystemActionEffects()

    // MARK: - Dispatch

    /// Where an action's work runs. Inline by default (tests, extra instances);
    /// AppDelegate points the shared instance at `workQueue`. The event tap runs on the
    /// main thread and now sees every mouse move, so anything slow an action does —
    /// AppleScript, AX calls into another (possibly hung) app, child processes — must
    /// not run inside the tap callback, or the whole system's mouse input stalls.
    var executor: (@escaping () -> Void) -> Void = { $0() }
    static let workQueue = DispatchQueue(label: "gesturekit.actions", qos: .userInitiated)

    /// AppKit-only state (NSScreen, NSApp) read from the work queue.
    static func onMain<T>(_ block: () -> T) -> T {
        Thread.isMainThread ? block() : DispatchQueue.main.sync(execute: block)
    }

    /// AX calls into other apps give up after this (default is ~6 s if the app hangs).
    static let axTimeout: Float = 0.5

    func perform(_ spec: ActionSpec) {
        Actions.observer?(spec)
        if let presenter = Actions.presenter {
            DispatchQueue.main.async { presenter(spec) }     // HUD never delays the tap
        }
        // typeText 的 label 含文字预览：日志里只写长度
        let label = spec.type == "typeText" ? "<\((spec.text ?? "").count) chars>" : (spec.label ?? "-")
        if !Actions.dryRun {
            effects.log("action type=\(spec.type) op=\(spec.op ?? "-") key=\(spec.keyCode.map(String.init) ?? "-") label=\(label)")
        }
        if Actions.dryRun {
            FileHandle.standardError.write(
                "[dry-run] action type=\(spec.type) op=\(spec.op ?? "-") key=\(spec.keyCode.map(String.init) ?? "-") label=\(label)\n".data(using: .utf8)!)
            return
        }
        executor { [self] in self.execute(spec) }
    }

    /// ⌘Q / 退出当前 App aimed at GestureKit itself (its settings window in front) would
    /// quit the gesture tool mid-use: skipped.
    static func quitsApp(_ spec: ActionSpec) -> Bool {
        spec.type == "quitApp"
            || (spec.type == "shortcut" && spec.keyCode == 12 && (spec.modifiers ?? 0) & 0x00100000 != 0)
    }

    private func execute(_ spec: ActionSpec) {
        if Actions.quitsApp(spec),
           effects.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            effects.log("skipped quit: GestureKit itself is frontmost")
            return
        }
        // ⌘Q is sent as a real quit request: apps like WeChat ignore a quick ⌘Q and want it
        // held ("按住 ⌘Q 退出"), so the gesture had to be done twice.
        if Actions.quitsApp(spec) { quitFrontApp(); return }
        switch spec.type {
        case "shortcut":   sendShortcut(keyCode: spec.keyCode ?? 0, modifiers: spec.modifiers ?? 0)
        case "window":     windowOp(spec.op ?? "")
        case "snap":       snapWindow(op: spec.op ?? "")
        case "system":     systemOp(spec.op ?? "")
        case "quitApp":    quitFrontApp()
        case "volume":
            if let level = effects.adjustOutputVolume(byPercent: spec.delta ?? 0) {
                // Setting the level directly shows no system indicator: show the new value instead.
                Actions.levelText(L("音量 %d%%", Int((level * 100).rounded())))
            } else {
                adjustVolume(spec.delta ?? 0)
            }
        case "brightness": effects.adjustBrightness(by: spec.delta ?? 0, target: spec.op)
        case "openApp":    openApplication(bundleID: spec.bundleID, path: spec.path)
        case "openURL":    openURLAction(spec.url)
        case "typeText":   typeText(spec.text ?? "")
        case "runShortcut": runShortcut(spec.shortcutName)
        default:           effects.log("unknown action type: \(spec.type)")
        }
    }

    // MARK: - Keyboard shortcut

    private func sendShortcut(keyCode: Int, modifiers: UInt32) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src,
                                 virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src,
                               virtualKey: CGKeyCode(keyCode), keyDown: false) else { return }
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        down.flags = flags
        up.flags = flags
        // Tag so our own tap ignores it (a rule "⌥← → ⌥←" would otherwise loop).
        for e in [down, up] {
            e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            effects.post(e)
        }
    }

    // MARK: - Mouse (synthetic clicks / scroll at the cursor)

    private enum MouseKind { case left, right, middle }

    private func mouse(_ kind: MouseKind, down: Bool) {
        let loc = CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType, button: CGMouseButton
        switch kind {
        case .left:   type = down ? .leftMouseDown : .leftMouseUp;   button = .left
        case .right:  type = down ? .rightMouseDown : .rightMouseUp; button = .right
        case .middle: type = down ? .otherMouseDown : .otherMouseUp; button = .center
        }
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc,
                              mouseButton: button) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
        effects.post(e)
    }

    private func click(_ kind: MouseKind) {
        mouse(kind, down: true)
        mouse(kind, down: false)
    }

    private func scrollHorizontal(_ pixels: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                              wheel1: 0, wheel2: pixels, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
        effects.post(e)
    }

    // MARK: - Window management (Accessibility API)

    private func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        effects.axCopy(el, name)
    }

    private func cfWindow(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func windows(of app: AXUIElement) -> [AXUIElement] {
        guard let value = axAttr(app, kAXWindowsAttribute as String) else { return [] }
        let array = value as! CFArray
        var result: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(array) {
            result.append(unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: AXUIElement.self))
        }
        return result
    }

    private func setMinimized(_ win: AXUIElement, _ minimized: Bool) {
        effects.axSet(win, kAXMinimizedAttribute as String, (minimized ? kCFBooleanTrue : kCFBooleanFalse))
    }

    private func isMinimized(_ win: AXUIElement) -> Bool {
        (axAttr(win, kAXMinimizedAttribute as String) as? Bool) ?? false
    }

    private func frontAppElement() -> AXUIElement? {
        guard let front = effects.frontmostApplication else { return nil }
        return Actions.axApp(front.processIdentifier)
    }

    /// AX element for an app, with a bounded messaging timeout.
    static func axApp(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        return app
    }

    private func windowOp(_ op: String) {
        switch op {
        case "minimize":
            guard let app = frontAppElement() else { return }
            let list = windows(of: app)
            let target = cfWindow(axAttr(app, kAXFocusedWindowAttribute as String)) ?? list.first
            if let w = target { setMinimized(w, true) }

        case "restore":
            // Restore the most recently minimized window of the front app,
            // falling back to any app with a minimized window.
            if let app = frontAppElement() {
                for w in windows(of: app) where isMinimized(w) {
                    setMinimized(w, false)
                    effects.axPerform(w, kAXRaiseAction as String)
                    return
                }
            }
            for running in effects.runningApplications where running.activationPolicy == .regular {
                let app = Actions.axApp(running.processIdentifier)
                for w in windows(of: app) where isMinimized(w) {
                    setMinimized(w, false)
                    NSRunningApplication(processIdentifier: running.processIdentifier)?
                        .activate(options: [.activateIgnoringOtherApps])
                    effects.axPerform(w, kAXRaiseAction as String)
                    return
                }
            }

        case "minimizeAll":
            for running in effects.runningApplications where running.activationPolicy == .regular {
                let app = Actions.axApp(running.processIdentifier)
                for w in windows(of: app) { setMinimized(w, true) }
            }
            if let front = effects.frontmostApplication { front.hide() }

        case "restoreAll":
            for running in effects.runningApplications where running.activationPolicy == .regular {
                let app = Actions.axApp(running.processIdentifier)
                for w in windows(of: app) where isMinimized(w) {
                    setMinimized(w, false)
                    effects.axPerform(w, kAXRaiseAction as String)
                }
            }

        case "fullscreen":
            guard let app = frontAppElement(),
                  let win = cfWindow(axAttr(app, kAXFocusedWindowAttribute as String))
            else { sendShortcut(keyCode: 3, modifiers: 0x00140000); return }
            let current = (axAttr(win, "AXFullScreen") as? Bool) ?? false
            let err = effects.axSet(win, "AXFullScreen", (current ? kCFBooleanFalse : kCFBooleanTrue))
            if err != .success { sendShortcut(keyCode: 3, modifiers: 0x00140000) }

        case "enterFullScreen", "exitFullScreen":
            guard let win = focusedWindow() else { return }
            let want = op == "enterFullScreen"
            if (axAttr(win, "AXFullScreen") as? Bool) == want { return }
            if effects.axSet(win, "AXFullScreen", want ? kCFBooleanTrue : kCFBooleanFalse) != .success {
                sendShortcut(keyCode: 3, modifiers: 0x00140000)
            }

        case "zoom":           // 标题栏绿色按钮的「缩放」
            guard let win = focusedWindow(),
                  let btn = axAttr(win, kAXZoomButtonAttribute as String) else { return }
            effects.axPerform(unsafeBitCast(btn, to: AXUIElement.self), kAXPressAction as String)

        case "smartZoom":
            smartZoom()


        case "restorePrevious":
            if let win = focusedWindow() { _ = restorePrevious(win) }

        case "moveToNextSpace": moveToAdjacentSpace(forward: true)
        case "moveToPrevSpace": moveToAdjacentSpace(forward: false)

        default:
            effects.log("unknown window op: \(op)")
        }
    }

    // MARK: - Window snapping

    private var mainHeight: CGFloat { Actions.onMain { NSScreen.screens.first?.frame.maxY ?? 0 } }

    private func focusedWindow() -> AXUIElement? {
        guard let app = frontAppElement() else { return nil }
        return cfWindow(axAttr(app, kAXFocusedWindowAttribute as String))
    }

    private func cocoaFrame(_ win: AXUIElement) -> CGRect? {
        currentFrame(win).map { WindowLayout.fromAX($0, mainHeight: mainHeight) }
    }

    private func setCocoaFrame(_ win: AXUIElement, _ r: CGRect) {
        setFrame(win, WindowLayout.toAX(r, mainHeight: mainHeight))
    }

    /// Visible frame of the screen holding most of `r` (Cocoa coords).
    private func visibleFrame(for r: CGRect) -> CGRect? {
        Actions.onMain {
            (NSScreen.screens.max { a, b in
                let ia = a.frame.intersection(r), ib = b.frame.intersection(r)
                return ia.width * ia.height < ib.width * ib.height
            } ?? NSScreen.main)?.visibleFrame
        }
    }

    /// Frames before our last move, for 「恢复上一次位置」 and smart zoom.
    private var previousFrames: [(window: AXUIElement, frame: CGRect)] = []

    private func remember(_ win: AXUIElement, _ frame: CGRect) {
        previousFrames.removeAll { CFEqual($0.window, win) }
        previousFrames.append((win, frame))
        if previousFrames.count > 30 { previousFrames.removeFirst() }
    }

    private func restorePrevious(_ win: AXUIElement) -> Bool {
        guard let i = previousFrames.lastIndex(where: { CFEqual($0.window, win) }) else { return false }
        let f = previousFrames.remove(at: i).frame
        setCocoaFrame(win, f)
        return true
    }

    private func snapWindow(op: String) {
        guard let layout = WindowLayout.Op(rawValue: op) else { effects.log("unknown snap op: \(op)"); return }
        guard let win = focusedWindow(),
              let cur = cocoaFrame(win), let visible = visibleFrame(for: cur) else { return }
        remember(win, cur)
        setCocoaFrame(win, WindowLayout.frame(for: layout, in: visible, current: cur))
    }

    /// 智能缩放：已最大化 → 回到之前的位置；否则最大化。
    private func smartZoom() {
        guard let win = focusedWindow(), let cur = cocoaFrame(win), let max = visibleFrame(for: cur) else { return }
        if WindowLayout.approximatelyEqual(cur, max), restorePrevious(win) { return }
        remember(win, cur)
        setCocoaFrame(win, max)
    }

    private func currentFrame(_ win: AXUIElement) -> CGRect? {
        guard let posV = axAttr(win, kAXPositionAttribute as String),
              let sizeV = axAttr(win, kAXSizeAttribute as String) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private func setFrame(_ win: AXUIElement, _ r: CGRect) {
        var p = r.origin, s = r.size
        effects.axSet(win, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &p)!)
        effects.axSet(win, kAXSizeAttribute as String, AXValueCreate(.cgSize, &s)!)
    }

    // MARK: - System actions

    private func systemOp(_ op: String) {
        switch op {
        case "missionControl": effects.coreDockNotify("com.apple.expose.awake")
        case "showDesktop":    effects.coreDockNotify("com.apple.expose.front.awake")
        case "launchpad":
            effects.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
        case "lockScreen":     effects.lockScreen()
        case "sleep":          runAppleScript("tell application \"System Events\" to sleep")
        case "emptyTrash":     effects.emptyTrash()
        case "hideOthers":
            for app in effects.runningApplications
            where app.activationPolicy == .regular && app != NSRunningApplication.current {
                app.hide()
            }
        case "toggleDarkMode":
            runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case "spotlight":      sendShortcut(keyCode: 49, modifiers: 0x00100000)   // ⌘Space
        case "appSwitcher":    sendShortcut(keyCode: 48, modifiers: 0x00100000)   // ⌘Tab

        // 媒体 / 亮度
        case "playPause":      sendSystemKey(16)
        case "nextTrack":      sendSystemKey(17)
        case "previousTrack":  sendSystemKey(18)
        case "volumeUp":       sendSystemKey(0)
        case "volumeDown":     sendSystemKey(1)
        case "mute":           sendSystemKey(7)

        // 截图
        case "screenshotRegion": screenshot(["-i", "-x"])
        case "screenshotWindow": screenshot(["-w", "-x"])
        case "screenshotFull":   screenshot(["-x"])

        // Finder 跳转
        case "openHome":        openPath("~")
        case "openDocuments":   openPath("~/Documents")
        case "openDownloads":   openPath("~/Downloads")
        case "openDesktop":     openPath("~/Desktop")
        case "openApplications": openPath("/Applications")
        case "openRoot":        openPath("/")
        case "newFinderWindow":
            effects.open(URL(fileURLWithPath: NSHomeDirectory()))

        // 系统开关
        case "toggleFnKeys":   toggleFnKeys()
        case "toggleWiFi":     toggleWiFi()
        case "toggleBluetooth": toggleBluetooth()
        case "switchInputSource": switchInputSource()

        // 窗口跨屏
        case "nextScreen":  moveToAdjacentScreen(forward: true)
        case "prevScreen":  moveToAdjacentScreen(forward: false)

        // 标签 / 页面导航（合成标准快捷键）
        case "newTab":        sendShortcut(keyCode: 17, modifiers: 0x00100000)   // ⌘T
        case "closeTab":      sendShortcut(keyCode: 13, modifiers: 0x00100000)   // ⌘W
        case "nextTab":       sendShortcut(keyCode: 48, modifiers: 0x00040000)   // ⌃⇥
        case "prevTab":       sendShortcut(keyCode: 48, modifiers: 0x00060000)   // ⌃⇧⇥
        case "pageBack":      sendShortcut(keyCode: 33, modifiers: 0x00100000)   // ⌘[
        case "pageForward":   sendShortcut(keyCode: 30, modifiers: 0x00100000)   // ⌘]
        case "pageTop":       sendShortcut(keyCode: 126, modifiers: 0x00100000)  // ⌘↑
        case "pageBottom":    sendShortcut(keyCode: 125, modifiers: 0x00100000)  // ⌘↓
        case "closeWindow":   sendShortcut(keyCode: 13, modifiers: 0x00100000)   // ⌘W

        // 桌面 / Dock / 文件
        case "toggleDock":       toggleDock()
        case "hideDesktopFiles": setDesktopFilesHidden(true)
        case "showDesktopFiles": setDesktopFilesHidden(false)

        // 电源
        case "shutdown":  runAppleScript("tell application \"System Events\" to shut down")
        case "restart":   runAppleScript("tell application \"System Events\" to restart")
        case "forceQuit": sendShortcut(keyCode: 53, modifiers: 0x00140000)       // ⌥⌘⎋

        // 打开系统设置 / 本 App 设置
        case "openSystemPreferences":
            effects.open(URL(string: "x-apple.systempreferences:")!)
        case "openSecurityPreferences":
            effects.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        case "openAppPreferences":
            effects.postNotification(Actions.openPreferencesNotification)
        case "quitGestureKit":    effects.terminateSelf()
        case "restartGestureKit": relaunchSelf()

        // App
        case "previousApp":       activatePreviousApp()
        case "siri":              openApp("/System/Applications/Siri.app")
        case "hideAllButFinder":
            for app in effects.runningApplications
            where app.activationPolicy == .regular && app.bundleIdentifier != "com.apple.finder" {
                app.hide()
            }
            effects.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?
                .activate(options: [])
        case "unhideAll":
            for app in effects.runningApplications where app.activationPolicy == .regular { app.unhide() }

        // Finder（导航类快捷键只在 Finder 在前台时发，避免在别的 App 里误操作）
        case "finderOpenSelected": finderOnlyShortcut(125, 0x00100000)     // ⌘↓
        case "finderEnclosing":    finderOnlyShortcut(126, 0x00100000)     // ⌘↑
        case "finderTrashSelected": finderOnlyShortcut(51, 0x00100000)     // ⌘⌫
        case "finderNewFolder":
            runAppleScript("tell application \"Finder\" to make new folder at (insertion location)")
        case "openNetwork":        finderShortcut(40, 0x00120000)          // ⇧⌘K
        case "openRecents":        openApp("/System/Library/CoreServices/Finder.app/Contents/Applications/Recents.app")
        case "openAirDrop":        openApp("/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        case "openICloudDrive":    openPath("~/Library/Mobile Documents/com~apple~CloudDocs")
        case "goToFolder":         finderShortcut(5, 0x00120000)           // ⇧⌘G
        case "connectToServer":    finderShortcut(40, 0x00100000)          // ⌘K

        // 显式开/关
        case "darkMode":
            runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to true")
        case "lightMode":
            runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to false")
        case "wifiOn":       setWiFi(on: true)
        case "wifiOff":      setWiFi(on: false)
        case "bluetoothOn":  setBluetooth(on: true)
        case "bluetoothOff": setBluetooth(on: false)
        case "screenSaver":  openApp("/System/Library/CoreServices/ScreenSaverEngine.app")

        // 键盘背光（NX_KEYTYPE_ILLUMINATION_UP/DOWN = 21/22，共 16 档）
        case "keyboardBacklightUp":     sendSystemKey(21)
        case "keyboardBacklightDown":   sendSystemKey(22)
        case "keyboardBacklightMax":    for _ in 0..<16 { sendSystemKey(21) }
        case "keyboardBacklightMin":    for _ in 0..<16 { sendSystemKey(22) }
        case "keyboardBacklightMiddle":
            for _ in 0..<16 { sendSystemKey(22) }
            for _ in 0..<8 { sendSystemKey(21) }

        // 鼠标 / 输入
        case "leftClick":    click(.left)
        case "rightClick":   click(.right)
        case "middleClick":  click(.middle)
        case "middleDown":   mouse(.middle, down: true)
        case "middleUp":     mouse(.middle, down: false)
        case "scrollLeft":   scrollHorizontal(120)
        case "scrollRight":  scrollHorizontal(-120)
        case "emojiPicker":  sendShortcut(keyCode: 49, modifiers: 0x00140000)   // ⌃⌘Space

        default:
            effects.log("unknown system op: \(op)")
        }
    }

    private func openApp(_ path: String) {
        effects.open(URL(fileURLWithPath: path))
    }

    private var isFinderFront: Bool {
        effects.frontmostBundleID == "com.apple.finder"
    }

    private func finderOnlyShortcut(_ key: Int, _ mods: UInt32) {
        guard isFinderFront else { effects.log("finder-only action skipped: Finder is not frontmost"); return }
        sendShortcut(keyCode: key, modifiers: mods)
    }

    /// Bring Finder forward, then send a Finder menu shortcut.
    private func finderShortcut(_ key: Int, _ mods: UInt32) {
        if isFinderFront { sendShortcut(keyCode: key, modifiers: mods); return }
        effects.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?
            .activate(options: [])
        effects.after(0.25) { [weak self] in
            self?.sendShortcut(keyCode: key, modifiers: mods)
        }
    }

    private func relaunchSelf() {
        effects.run("/bin/sh", ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath], wait: false)
        effects.terminateSelf()
    }

    // MARK: - Previous application

    private var appHistory = AppHistory()
    private var activationObserver: Any?

    /// Start recording app activations (call once at launch).
    func startTracking() {
        guard activationObserver == nil else { return }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { appHistory.activated(pid) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app != NSRunningApplication.current else { return }
            self?.appHistory.activated(app.processIdentifier)
        }
    }

    private func activatePreviousApp() {
        let running = effects.runningApplications
        let alive = Set(running.map(\.processIdentifier))
        guard let pid = Actions.onMain({ appHistory.previous(alive: alive) }) else { return }
        running.first { $0.processIdentifier == pid }?.activate(options: [.activateIgnoringOtherApps])
    }

    /// Media / brightness keys via NX_KEYTYPE system-defined events.
    private func sendSystemKey(_ key: Int32) {
        for down in [true, false] {
            // NX_SYSDEFINED data1: key code in bits 16–31, key state (0xA down / 0xB up) in bits 8–15
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00 << 16),
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 8, data1: data1, data2: -1) else { continue }
            if let cg = e.cgEvent { effects.post(cg) }
        }
    }

    private func screenshot(_ args: [String]) {
        let out = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/shot-\(Int(Date().timeIntervalSince1970)).png")
        effects.run("/usr/sbin/screencapture", args + [out.path], wait: false)
    }

    private func openPath(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        effects.open(URL(fileURLWithPath: expanded))
    }

    private func moveToAdjacentScreen(forward: Bool) {
        guard let win = focusedWindow(), let cur = cocoaFrame(win) else { return }
        // All in Cocoa coordinates (screens' visibleFrame and the window frame).
        let screens = Actions.onMain { NSScreen.screens.map { $0.visibleFrame } }
        guard let target = WindowLayout.movedToAdjacentScreen(
            currentFrame: cur, screens: screens, size: cur.size, forward: forward) else { return }
        remember(win, cur)
        setCocoaFrame(win, target)
    }

    private func toggleDock() {
        let cur = effects.run("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"], wait: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        effects.run("/usr/bin/defaults",
                    ["write", "com.apple.dock", "autohide", "-bool", cur == "1" ? "false" : "true"], wait: true)
        effects.run("/usr/bin/killall", ["Dock"], wait: false)
    }

    private func setDesktopFilesHidden(_ hidden: Bool) {
        effects.run("/usr/bin/find",
                    [NSHomeDirectory() + "/Desktop", "-maxdepth", "1", "-mindepth", "1",
                     "-exec", "/usr/bin/chflags", hidden ? "hidden" : "nohidden", "{}", ";"], wait: false)
    }

    private func toggleFnKeys() {
        // 读全局域当前值 → 取反写回
        let cur = effects.run("/usr/bin/defaults", ["read", "-g", "com.apple.keyboard.fnState"], wait: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        effects.run("/usr/bin/defaults",
                    ["write", "-g", "com.apple.keyboard.fnState", "-bool", cur == "1" ? "false" : "true"], wait: true)
    }

    private func wifiInterface() -> String {
        // 找出 Wi-Fi 接口名
        let text = effects.run("/usr/sbin/networksetup", ["-listallhardwareports"], wait: true)
        var iface = "en0"
        let lines = text.split(separator: "\n")
        for (i, l) in lines.enumerated() where l.contains("Wi-Fi") {
            if i + 1 < lines.count, lines[i+1].contains("Device:") {
                iface = lines[i+1].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return iface
    }

    private func toggleWiFi() {
        let iface = wifiInterface()
        // 读取当前状态后取反
        let state = effects.run("/usr/sbin/networksetup", ["-getairportpower", iface], wait: true)
        setWiFi(on: !state.contains("On"), iface: iface)
    }

    private func setWiFi(on: Bool, iface: String? = nil) {
        effects.run("/usr/sbin/networksetup", ["-setairportpower", iface ?? wifiInterface(), on ? "on" : "off"],
                    wait: false)
    }

    private func toggleBluetooth() {
        guard let cur = effects.bluetoothPower() else { return }
        effects.setBluetoothPower(cur == 1 ? 0 : 1)
    }

    private func setBluetooth(on: Bool) {
        effects.setBluetoothPower(on ? 1 : 0)
    }

    private func switchInputSource() {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource],
              !list.isEmpty else { return }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var next = false
        for src in list {
            if next { effects.selectInputSource(src); return }
            if let c = current, CFEqual(c, src) { next = true }
        }
        if let first = list.first { effects.selectInputSource(first) }
    }

    private func runAppleScript(_ source: String) {
        effects.runAppleScript(source)
    }

    // MARK: - Open app / URL, type text, run shortcut

    /// bundleID first (LaunchServices finds it wherever it moved), then the saved
    /// .app path, then an already-running app with that bundle id.
    private func openApplication(bundleID: String?, path: String?) {
        let bid = (bundleID ?? "").trimmingCharacters(in: .whitespaces)
        if !bid.isEmpty, let url = effects.applicationURL(bundleID: bid) {
            effects.openApplication(url); return
        }
        let p = ((path ?? "").trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !p.isEmpty, effects.fileExists(p) {
            effects.openApplication(URL(fileURLWithPath: p)); return
        }
        if !bid.isEmpty, let running = effects.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
            running.activate(options: [.activateIgnoringOtherApps]); return
        }
        effects.log("openApp: app not found (bundleID=\(bid.isEmpty ? "-" : bid))")
    }

    /// What 「打开网址或文件」 opens for the text the user typed; nil = empty / unusable.
    /// "/…" or "~…" → file URL; "scheme:…" → as is; bare "example.com/x" → https://.
    static func resolveURL(_ raw: String?) -> URL? {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("/") || s.hasPrefix("~") {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        if let colon = s.firstIndex(of: ":") {
            let scheme = String(s[..<colon]), rest = s[s.index(after: colon)...]
            // "example.com:8080" / "localhost:3000" is host:port, not a scheme
            let isPort = (scheme.contains(".") || scheme == "localhost") && rest.first?.isNumber == true
            if !isPort, scheme.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil {
                return URL(string: s)
            }
        }
        guard !s.contains(" "), s.contains(".") || s.hasPrefix("localhost") else { return nil }
        return URL(string: "https://" + s)
    }

    private func openURLAction(_ raw: String?) {
        guard let url = Actions.resolveURL(raw) else { effects.log("openURL skipped: empty or invalid"); return }
        if url.isFileURL, !effects.fileExists(url.path) {
            effects.log("openURL: path not found"); return
        }
        effects.open(url)
    }

    /// Unicode chunk size per key event (keyboardSetUnicodeString is reliable up to 20 UTF-16 units).
    static let typeChunk = 20

    /// Types `text` as tagged unicode key events; newlines become Return presses.
    /// Only the length goes to the log, never the text.
    private func typeText(_ text: String) {
        guard !text.isEmpty else { effects.log("typeText skipped: empty"); return }
        effects.log("typeText: \(text.count) chars")
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            postUnicode(chunk)
            chunk.removeAll()
        }
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                flush()
                sendShortcut(keyCode: 36, modifiers: 0)                           // ↩
                continue
            }
            let units = Array(String(ch).utf16)                                   // keep graphemes whole
            if chunk.count + units.count > Actions.typeChunk { flush() }
            chunk += units
        }
        flush()
    }

    private func postUnicode(_ units: [UniChar]) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return }
            e.flags = []                    // a held trigger modifier must not turn text into shortcuts
            units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            effects.post(e)
        }
    }

    /// `shortcuts run <name>` without waiting (a long shortcut must not stall the event tap).
    private func runShortcut(_ name: String?) {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { effects.log("runShortcut skipped: no name"); return }
        effects.run("/usr/bin/shortcuts", ["run", n], wait: false)
    }

    // MARK: - Move window to adjacent Space (experimental)

    /// No public API: hold the mouse on the front window's title bar, send ⌃→/⌃←
    /// (系统「移到左/右侧空间」快捷键须开启), then release. Only runs when a front
    /// window and a title-bar point next to its traffic-light buttons can be found.
    /// A mouse gesture fires on the *first* button release, so the other button is
    /// often still held; a synthetic title-bar drag would clash with it. Wait up to
    /// ~1s for all buttons to come up, otherwise skip.
    private func moveToAdjacentSpace(forward: Bool, attempt: Int = 0) {
        if effects.mouseButtonHeld {
            guard attempt < 20 else { effects.log("space move skipped: mouse button still held"); return }
            effects.after(0.05) { [weak self] in self?.moveToAdjacentSpace(forward: forward, attempt: attempt + 1) }
            return
        }
        guard let win = focusedWindow(), let frame = currentFrame(win),
              let button = axAttr(win, kAXZoomButtonAttribute as String)
                ?? axAttr(win, kAXMinimizeButtonAttribute as String),
              let buttonFrame = currentFrame(unsafeBitCast(button, to: AXUIElement.self)) else {
            effects.log("space move skipped: no front window or title bar"); return
        }
        // AX coordinates (top-left origin) for both rects and the event location.
        let grab = CGPoint(x: buttonFrame.maxX + 8, y: buttonFrame.midY)
        guard frame.contains(grab), grab.y - frame.minY < 40, frame.maxX - grab.x > 20 else {
            effects.log("space move skipped: title bar point outside window"); return
        }
        let back = effects.cursorLocation
        postMouse(.leftMouseDown, at: grab)
        postMouse(.leftMouseDragged, at: grab)
        effects.after(0.05) { [weak self] in
            self?.sendShortcut(keyCode: forward ? 124 : 123, modifiers: 0x00040000)   // ⌃→ / ⌃←
            self?.effects.after(0.35) { [weak self] in
                self?.postMouse(.leftMouseUp, at: grab)
                self?.postMouse(.mouseMoved, at: back)
            }
        }
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
        effects.post(e)
    }

    private func quitFrontApp() {
        if let app = effects.frontmostApplication { effects.terminate(app) }
    }

    // MARK: - Volume (system output)

    private func adjustVolume(_ delta: Double) {
        let script = """
        set v to output volume of (get volume settings)
        set nv to v + \(Int(delta))
        if nv > 100 then set nv to 100
        if nv < 0 then set nv to 0
        set volume output volume nv
        """
        effects.runAppleScript(script)
    }
}

/// Most-recent-first list of activated apps, for 「上一个应用」.
struct AppHistory {
    private(set) var pids: [pid_t] = []

    mutating func activated(_ pid: pid_t) {
        pids.removeAll { $0 == pid }
        pids.insert(pid, at: 0)
        if pids.count > 20 { pids.removeLast() }
    }

    /// The app before the current one that is still running.
    func previous(alive: Set<pid_t>) -> pid_t? {
        pids.dropFirst().first { alive.contains($0) }
    }
}

// MARK: - Side-effect seam

/// Everything an action does to the outside world. `Actions` only decides
/// *what* to do (which event, which script, which path); this protocol does it.
/// `SystemActionEffects` is the real thing; the selftest uses a recorder
/// (SelfTest+Actions.swift) so `perform` can run for real without touching the Mac.
protocol ActionEffects: AnyObject {
    // Reads that decide behaviour
    var frontmostApplication: NSRunningApplication? { get }
    /// Ask an app to quit (the same request as 「退出」 in its Dock / menu-bar menu).
    func terminate(_ app: NSRunningApplication)
    var frontmostBundleID: String? { get }
    var runningApplications: [NSRunningApplication] { get }

    // Events (keys, mouse, scroll, NX system keys) — already tagged by Actions
    func post(_ event: CGEvent)

    // Accessibility
    func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef?
    @discardableResult func axSet(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError
    func axPerform(_ element: AXUIElement, _ action: String)

    // Processes / scripts / URLs
    /// Launches `path`; with `wait` it blocks and returns stdout ("" otherwise).
    @discardableResult func run(_ path: String, _ args: [String], wait: Bool) -> String
    func runAppleScript(_ source: String)
    func open(_ url: URL)
    /// LaunchServices lookup; nil when no app has this bundle id.
    func applicationURL(bundleID: String) -> URL?
    /// Launch or bring forward the .app at `url`.
    func openApplication(_ url: URL)
    func fileExists(_ path: String) -> Bool
    var cursorLocation: CGPoint { get }
    /// Any of left/right/middle physically held (a gesture's last button may still be down).
    var mouseButtonHeld: Bool { get }

    // Private frameworks / system services
    func coreDockNotify(_ name: String)
    func lockScreen()
    func bluetoothPower() -> Int32?
    func setBluetoothPower(_ state: Int32)
    func selectInputSource(_ source: TISInputSource)
    func adjustBrightness(by delta: Double, target: String?)
    /// System output volume ± `percent` (0…100 scale) → the new level 0…1;
    /// nil = device has no settable volume.
    func adjustOutputVolume(byPercent percent: Double) -> Float?
    func emptyTrash()

    // App-level
    func postNotification(_ name: Notification.Name)
    func terminateSelf()
    func after(_ seconds: Double, _ block: @escaping () -> Void)
    func log(_ message: String)
}

/// The real side effects (what GestureKit always did before the seam existed).
final class SystemActionEffects: ActionEffects {

    var frontmostApplication: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    func terminate(_ app: NSRunningApplication) { app.terminate() }
    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var runningApplications: [NSRunningApplication] { NSWorkspace.shared.runningApplications }

    func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }

    func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    @discardableResult
    func axSet(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    func axPerform(_ element: AXUIElement, _ action: String) {
        AXUIElementPerformAction(element, action as CFString)
    }

    @discardableResult
    func run(_ path: String, _ args: [String], wait: Bool) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        guard wait else { try? p.run(); return "" }
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Out of process and fire-and-forget: NSAppleScript in-process took up to ~130 ms
    /// on first use and is not safe off the main thread.
    func runAppleScript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { Log.write("osascript failed: \(error.localizedDescription)") }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func openApplication(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if let error { Log.write("openApp failed: \(error.localizedDescription)") }
        }
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }
    var mouseButtonHeld: Bool {
        [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
    }

    func coreDockNotify(_ name: String) {
        typealias Fn = @convention(c) (CFString) -> Void
        guard let h = dlopen("/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock", RTLD_NOW),
              let sym = dlsym(h, "CoreDockSendNotification") else { return }
        unsafeBitCast(sym, to: Fn.self)(name as CFString)
    }

    func lockScreen() {
        typealias Fn = @convention(c) () -> Void
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return }
        unsafeBitCast(sym, to: Fn.self)()
    }

    private func bluetoothSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
        else { return nil }
        return dlsym(h, name)
    }

    func bluetoothPower() -> Int32? {
        typealias GetFn = @convention(c) () -> Int32
        guard let sym = bluetoothSymbol("IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(sym, to: GetFn.self)()
    }

    func setBluetoothPower(_ state: Int32) {
        typealias SetFn = @convention(c) (Int32) -> Void
        guard let sym = bluetoothSymbol("IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(sym, to: SetFn.self)(state)
    }

    func selectInputSource(_ source: TISInputSource) { TISSelectInputSource(source) }

    func adjustBrightness(by delta: Double, target: String?) {
        Actions.onMain { DisplayBrightness.adjust(by: delta, target: target) }   // reads NSScreen / cursor
    }

    func adjustOutputVolume(byPercent percent: Double) -> Float? {
        OutputVolume.adjust(byPercent: percent)
    }

    func emptyTrash() {
        let fm = FileManager.default
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        guard let items = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    func postNotification(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    func terminateSelf() { DispatchQueue.main.async { NSApp.terminate(nil) } }

    func after(_ seconds: Double, _ block: @escaping () -> Void) {
        // Same queue as the action itself, so follow-up steps never run on the tap thread.
        Actions.workQueue.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    func log(_ message: String) { Log.write(message) }
}
