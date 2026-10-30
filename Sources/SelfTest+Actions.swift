import Cocoa
import Carbon

// P2-17 动作层单测：用记录型 ActionEffects 跑真实的 Actions.perform 路径
// （dryRun 关掉），断言每个动作会产生的副作用。自检里绝不真的发按键、开 App、
// 跑脚本或动窗口——所有效果都只记录在 RecordingActionEffects 里。

/// Test double for `ActionEffects`: records every call, touches nothing.
/// Reads return "nothing is running / no window", so AX paths stay inert.
final class RecordingActionEffects: ActionEffects {

    enum Call {
        case post(CGEvent)
        case axSet(String), axPerform(String)
        case run(String, [String], wait: Bool)
        case appleScript(String), terminate(String)
        case volume(Double)
        case open(URL), openApplication(URL)
        case coreDock(String), lockScreen, setBluetooth(Int32), selectInputSource
        case brightness(Double, String?), emptyTrash
        case notification(Notification.Name), terminateSelf
        case after(Double)
    }

    private(set) var calls: [Call] = []
    private(set) var logs: [String] = []

    /// Canned stdout for `run(_:_:wait:)`.
    var processOutput: (String, [String]) -> String = { _, _ in "" }
    var frontmostBundleID: String?
    var bluetoothState: Int32? = 1

    /// Defaults keep every AX path inert; actionExtChecks sets these to fake a window.
    var frontApp: NSRunningApplication?
    var axHook: ((AXUIElement, String) -> CFTypeRef?)?
    /// bundle id → app URL for `applicationURL(bundleID:)`; paths for `fileExists`.
    var installedApps: [String: URL] = [:]
    var existingPaths: Set<String> = []
    var cursor = CGPoint(x: 1, y: 2)

    var frontmostApplication: NSRunningApplication? { frontApp }
    var runningApplications: [NSRunningApplication] { [] }

    func post(_ event: CGEvent) { calls.append(.post(event.copy() ?? event)) }
    func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? { axHook?(element, attribute) }
    @discardableResult
    func axSet(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        calls.append(.axSet(attribute)); return .failure
    }
    func axPerform(_ element: AXUIElement, _ action: String) { calls.append(.axPerform(action)) }
    @discardableResult
    func run(_ path: String, _ args: [String], wait: Bool) -> String {
        calls.append(.run(path, args, wait: wait))
        return wait ? processOutput(path, args) : ""
    }
    func runAppleScript(_ source: String) { calls.append(.appleScript(source)) }
    /// false = pretend the output device has no settable volume (exercises the AppleScript fallback).
    var outputVolumeSettable = false
    func adjustOutputVolume(byPercent percent: Double) -> Float? {
        calls.append(.volume(percent))
        return outputVolumeSettable ? 0.64 : nil
    }
    func open(_ url: URL) { calls.append(.open(url)) }
    func applicationURL(bundleID: String) -> URL? { installedApps[bundleID] }
    func openApplication(_ url: URL) { calls.append(.openApplication(url)) }
    func terminate(_ app: NSRunningApplication) { calls.append(.terminate(app.bundleIdentifier ?? "?")) }
    func fileExists(_ path: String) -> Bool { existingPaths.contains(path) }
    var cursorLocation: CGPoint { cursor }
    /// Physical button state seen by actions; tests flip it to simulate a held button.
    var buttonHeldFor = 0                  // report "held" for this many queries, then released
    var mouseButtonHeld: Bool {
        if buttonHeldFor > 0 { buttonHeldFor -= 1; return true }
        return false
    }
    func coreDockNotify(_ name: String) { calls.append(.coreDock(name)) }
    func lockScreen() { calls.append(.lockScreen) }
    func bluetoothPower() -> Int32? { bluetoothState }
    func setBluetoothPower(_ state: Int32) { calls.append(.setBluetooth(state)) }
    func selectInputSource(_ source: TISInputSource) { calls.append(.selectInputSource) }
    func adjustBrightness(by delta: Double, target: String?) { calls.append(.brightness(delta, target)) }
    func emptyTrash() { calls.append(.emptyTrash) }
    func postNotification(_ name: Notification.Name) { calls.append(.notification(name)) }
    func terminateSelf() { calls.append(.terminateSelf) }
    /// Runs the block immediately so delayed work never escapes the test.
    func after(_ seconds: Double, _ block: @escaping () -> Void) { calls.append(.after(seconds)); block() }
    func log(_ message: String) { logs.append(message) }

    // MARK: Decoded views

    var events: [CGEvent] { calls.compactMap { if case .post(let e) = $0 { return e }; return nil } }

    /// (keyCode, modifier flags, isDown, tagged) for each synthesized key event.
    var keys: [(code: Int, flags: UInt64, down: Bool, tagged: Bool)] {
        events.filter { $0.type == .keyDown || $0.type == .keyUp }.map {
            (Int($0.getIntegerValueField(.keyboardEventKeycode)),
             $0.flags.rawValue & 0x00FF_0000,               // device-independent modifier bits
             $0.type == .keyDown,
             $0.getIntegerValueField(.eventSourceUserData) == Actions.syntheticMarker)
        }
    }

    /// (NX key type, isDown) for each NX_SYSDEFINED media/backlight event.
    var systemKeys: [(key: Int, down: Bool)] {
        events.compactMap { e in
            guard let ns = NSEvent(cgEvent: e), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return nil }
            // Key state 0xA = down / 0xB = up, in bits 8–15 (NX convention). A state in the
            // low byte reads as 0 here, so the down/up checks fail.
            let state = (ns.data1 & 0xFF00) >> 8
            return ((ns.data1 >> 16) & 0xFFFF, state == 0xa)
        }
    }

    var unknownLogs: [String] { logs.filter { $0.hasPrefix("unknown") } }
}

extension SelfTest {
    static func actionChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }

        // Global state we flip; restored at the end no matter what.
        let savedDryRun = Actions.dryRun, savedObserver = Actions.observer, savedPresenter = Actions.presenter
        Actions.dryRun = false
        Actions.observer = nil
        Actions.presenter = nil
        defer {
            Actions.dryRun = savedDryRun
            Actions.observer = savedObserver
            Actions.presenter = savedPresenter
        }

        /// Fresh Actions (never `.shared`) wired to a fresh recorder.
        func run(_ spec: ActionSpec, setup: (RecordingActionEffects) -> Void = { _ in }) -> RecordingActionEffects {
            let fx = RecordingActionEffects()
            setup(fx)
            let actions = Actions()
            actions.effects = fx
            actions.perform(spec)
            return fx
        }
        func system(_ op: String, setup: (RecordingActionEffects) -> Void = { _ in }) -> RecordingActionEffects {
            run(ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: nil, op: op, delta: nil), setup: setup)
        }
        /// Exactly one down+up of `code` with `flags`, both tagged.
        func isShortcut(_ fx: RecordingActionEffects, _ code: Int, _ flags: UInt64) -> Bool {
            let k = fx.keys
            return k.count == 2 && k[0].down && !k[1].down
                && k.allSatisfy { $0.code == code && $0.flags == flags && $0.tagged }
        }
        func describeKeys(_ fx: RecordingActionEffects) -> String {
            fx.keys.map { "\($0.code)/\(String($0.flags, radix: 16))/\($0.down ? "d" : "u")\($0.tagged ? "" : "!tag")" }
                .joined(separator: " ")
        }

        // MARK: Seam defaults
        check("actions: shared instance uses real SystemActionEffects", Actions.shared.effects is SystemActionEffects)

        // MARK: shortcut
        do {
            let fx = run(ActionSpec(type: "shortcut", keyCode: 30, modifiers: 0x00100000, label: "⌘]", op: nil, delta: nil))
            check("actions: shortcut ⌘] posts tagged keyDown+keyUp (30, ⌘)", isShortcut(fx, 30, 0x00100000), describeKeys(fx))
            check("actions: shortcut logs the action line", fx.logs.first?.hasPrefix("action type=shortcut") == true)
            let fx2 = run(ActionSpec(type: "shortcut", keyCode: 123, modifiers: 0x00180000, label: "⌥⌘←", op: nil, delta: nil))
            check("actions: shortcut keeps combined modifiers (⌥⌘←)", isShortcut(fx2, 123, 0x00180000), describeKeys(fx2))
        }

        // MARK: volume / brightness
        do {
            let savedLevel = Actions.levelPresenter
            var levels: [String] = []
            Actions.levelPresenter = { levels.append($0) }
            let fx = run(ActionSpec(type: "volume", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: 6)) {
                $0.outputVolumeSettable = true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))      // level text is posted to main
            Actions.levelPresenter = savedLevel
            check("actions: volume change shows the new level in the HUD", levels == [L("音量 %d%%", 64)], "\(levels)")
            let viaCoreAudio = fx.calls.count == 1 && { if case .volume(6) = fx.calls[0] { return true }; return false }()
            check("actions: volume +6 goes through CoreAudio (no AppleScript)", viaCoreAudio)
            let fb = run(ActionSpec(type: "volume", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: 6))
            let ok = fb.calls.count == 2 && { if case .appleScript(let s) = fb.calls[1] {
                return s.contains("set nv to v + 6") && s.contains("set volume output volume nv") }; return false }()
            check("actions: volume falls back to AppleScript when the device has no settable volume", ok)
            let fxDown = run(ActionSpec(type: "volume", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: -6))
            let okDown = { if case .volume(-6)? = fxDown.calls.first { return true }; return false }()
            check("actions: volume -6 passes a negative delta", okDown)
            check("actions: volume step math", OutputVolume.next(0.5, byPercent: 6) == 0.56
                  && OutputVolume.next(0.97, byPercent: 6) == 1 && OutputVolume.next(0.02, byPercent: -6) == 0)

            let fxB = run(ActionSpec(type: "brightness", keyCode: nil, modifiers: nil, label: nil, op: "external", delta: -0.0625))
            let okB = fxB.calls.count == 1 && { if case .brightness(let d, let t) = fxB.calls[0] {
                return d == -0.0625 && t == "external" }; return false }()
            check("actions: brightness goes to DisplayBrightness with delta+target", okB)
        }

        // MARK: never quit GestureKit itself
        do {
            let cmdQ = ActionSpec(type: "shortcut", keyCode: 12, modifiers: 0x00100000, label: "⌘Q", op: nil, delta: nil)
            let me = NSRunningApplication.current
            let selfFront = run(cmdQ) { $0.frontApp = me }
            check("actions: ⌘Q is not sent while GestureKit itself is frontmost",
                  selfFront.keys.isEmpty && selfFront.logs.contains { $0.contains("skipped quit") })
            let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
            let other = run(cmdQ) { $0.frontApp = finder }
            let quitOK = other.keys.isEmpty && other.calls.contains { if case .terminate("com.apple.finder") = $0 { return true }; return false }
            check("actions: ⌘Q asks the front app to quit (not a quick key press WeChat ignores)", finder == nil || quitOK,
                  "\(other.calls)")
            check("actions: 退出当前 App counts as quitting",
                  Actions.quitsApp(ActionSpec(type: "quitApp", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil))
                  && !Actions.quitsApp(ActionSpec(type: "shortcut", keyCode: 13, modifiers: 0x00100000, label: nil, op: nil, delta: nil)))
        }

        // MARK: representative system ops
        do {
            let t = system("newTab")
            check("actions: system newTab = ⌘T", isShortcut(t, 17, 0x00100000), describeKeys(t))
            let e = system("emojiPicker")
            check("actions: system emojiPicker = ⌃⌘Space", isShortcut(e, 49, 0x00140000), describeKeys(e))

            let mc = system("missionControl")
            let okMC = mc.calls.count == 1 && { if case .coreDock(let n) = mc.calls[0] { return n == "com.apple.expose.awake" }
                return false }()
            check("actions: system missionControl → CoreDock expose.awake", okMC)

            let kb = system("keyboardBacklightMax")
            let sk = kb.systemKeys
            check("actions: keyboardBacklightMax = 16× NX key 21 (down+up)",
                  sk.count == 32 && sk.allSatisfy { $0.key == 21 }
                      && sk.enumerated().allSatisfy { $0.element.down == ($0.offset % 2 == 0) },
                  "got \(sk.count) system keys")
            let kbMid = system("keyboardBacklightMiddle").systemKeys
            check("actions: keyboardBacklightMiddle = 16× key 22 then 8× key 21",
                  kbMid.count == 48 && kbMid.prefix(32).allSatisfy { $0.key == 22 } && kbMid.suffix(16).allSatisfy { $0.key == 21 })
            let pp = system("playPause").systemKeys
            check("actions: playPause = NX key 16 down+up", pp.count == 2 && pp.allSatisfy { $0.key == 16 })

            let trashAway = system("finderTrashSelected") { $0.frontmostBundleID = "com.apple.Safari" }
            check("actions: finderTrashSelected sends nothing when Finder is not frontmost",
                  trashAway.events.isEmpty && trashAway.logs.contains { $0.hasPrefix("finder-only action skipped") })
            let trashFront = system("finderTrashSelected") { $0.frontmostBundleID = "com.apple.finder" }
            check("actions: finderTrashSelected sends ⌘⌫ when Finder is frontmost",
                  isShortcut(trashFront, 51, 0x00100000), describeKeys(trashFront))

            let net = system("goToFolder")
            check("actions: goToFolder off-Finder waits 0.25s then sends ⇧⌘G",
                  { if case .after(let s)? = net.calls.first { return s == 0.25 }; return false }()
                      && isShortcut(net, 5, 0x00120000), describeKeys(net))

            let dl = system("openDownloads")
            let wantDL = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
            let okDL = dl.calls.count == 1 && { if case .open(let u) = dl.calls[0] { return u.path == wantDL }; return false }()
            check("actions: openDownloads opens ~/Downloads", okDL)

            let click = system("leftClick")
            let types = click.events.map(\.type)
            check("actions: leftClick posts tagged leftMouseDown+leftMouseUp",
                  types == [.leftMouseDown, .leftMouseUp]
                      && click.events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == Actions.syntheticMarker })
            let scroll = system("scrollLeft").events
            check("actions: scrollLeft posts one tagged scroll event (+120px on axis 2)",
                  scroll.count == 1 && scroll[0].type == .scrollWheel
                      && scroll[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 120
                      && scroll[0].getIntegerValueField(.eventSourceUserData) == Actions.syntheticMarker)

            let shot = system("screenshotRegion")
            let okShot = { if case .run(let p, let a, let w)? = shot.calls.first {
                return p == "/usr/sbin/screencapture" && Array(a.prefix(2)) == ["-i", "-x"] && !w
                    && (a.last ?? "").hasSuffix(".png") }; return false }()
            check("actions: screenshotRegion launches screencapture -i -x <png>", okShot)

            let dock = system("toggleDock") { $0.processOutput = { _, a in a.first == "read" ? "1\n" : "" } }
            let dockArgs = dock.calls.compactMap { c -> [String]? in if case .run(_, let a, _) = c { return a }; return nil }
            check("actions: toggleDock flips autohide 1 → false and restarts Dock",
                  dockArgs.count == 3 && dockArgs[1].last == "false" && dockArgs[2] == ["Dock"])

            let bt = system("toggleBluetooth") { $0.bluetoothState = 1 }
            check("actions: toggleBluetooth on → off",
                  { if case .setBluetooth(let s)? = bt.calls.first { return s == 0 }; return false }())

            let prefs = system("openAppPreferences")
            check("actions: openAppPreferences posts the open-preferences notification",
                  { if case .notification(let n)? = prefs.calls.first { return n == Actions.openPreferencesNotification }
                    return false }())
            let quit = system("quitGestureKit")
            check("actions: quitGestureKit terminates via the seam",
                  { if case .terminateSelf? = quit.calls.first { return true }; return false }())

            let fs = run(ActionSpec(type: "window", keyCode: nil, modifiers: nil, label: nil, op: "fullscreen", delta: nil))
            check("actions: window fullscreen without a window falls back to ⌃⌘F",
                  isShortcut(fs, 3, 0x00140000), describeKeys(fs))
        }

        // MARK: every catalog choice is recognised by perform
        do {
            // These legitimately do nothing when no app/window is around (recorder reports none).
            let inertWithoutApps: Set<String> = ["hideOthers", "hideAllButFinder", "unhideAll", "previousApp",
                                                 "nextScreen", "prevScreen"]
            var unknown: [String] = [], silent: [String] = []
            let choices = ActionCatalog.choices
            for choice in choices {
                let fx = run(choice.spec)
                if !fx.unknownLogs.isEmpty { unknown.append(choice.id) }
                // Ignore the leading "action type=…" log line; anything else is a real effect.
                let didSomething = !fx.calls.isEmpty || fx.logs.count > 1
                if choice.spec.type == "system", !didSomething, !inertWithoutApps.contains(choice.spec.op ?? "") {
                    silent.append(choice.id)
                }
            }
            check("actions: every ActionCatalog choice (\(choices.count)) is handled by perform",
                  unknown.isEmpty && choices.count > 100, unknown.joined(separator: ", "))
            check("actions: every catalog system op produces an effect", silent.isEmpty, silent.joined(separator: ", "))
            let names = Set(ActionCatalog.systemNames.keys)
            let grouped = ActionCatalog.systemGroups.flatMap { $0.1 }
            check("actions: systemGroups lists every systemNames key exactly once",
                  Set(grouped) == names && grouped.count == names.count)
        }

        // MARK: unknown input does not crash
        do {
            let fx = system("definitelyNotAnOp")
            check("actions: unknown system op is logged, no effects",
                  fx.calls.isEmpty && fx.unknownLogs == ["unknown system op: definitelyNotAnOp"])
            let w = run(ActionSpec(type: "window", keyCode: nil, modifiers: nil, label: nil, op: "nope", delta: nil))
            check("actions: unknown window op is logged", w.calls.isEmpty && w.unknownLogs.count == 1)
            let s = run(ActionSpec(type: "snap", keyCode: nil, modifiers: nil, label: nil, op: "nope", delta: nil))
            check("actions: unknown snap op is logged", s.calls.isEmpty && s.unknownLogs.count == 1)
            let t = run(ActionSpec(type: "teleport", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil))
            check("actions: unknown action type is logged", t.calls.isEmpty && t.unknownLogs.count == 1)
        }

        // MARK: dry-run still short-circuits before any effect
        do {
            Actions.dryRun = true
            var seen = 0
            Actions.observer = { _ in seen += 1 }
            let fx = system("newTab")
            check("actions: dry-run notifies observer but produces no effects", seen == 1 && fx.calls.isEmpty && fx.logs.isEmpty)
            Actions.observer = nil
            Actions.dryRun = false
        }

        return out
    }
}
