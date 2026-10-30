import Cocoa

/// Recognises the gestures the user actually configured and dispatches actions.
///
/// Threading (app): every member is used on the tap thread only (`TapThread`). The app
/// changes `config` / `paused` through `TapThread.perform`; outside updates (screen
/// layout, front app) come back through `engineQueue`; the trail goes to the main thread
/// from `onChordStroke`. Selftests leave all hooks synchronous.
final class GestureEngine {

    var config: Config {
        didSet { rulesetCache = [:] }
    }
    /// Runs a state update on the engine's own thread. App: TapThread.perform; selftest: inline.
    var engineQueue: (@escaping () -> Void) -> Void = { $0() }
    /// Trail updates are sent at most this often while drawing (0 = every point, selftest).
    var strokeInterval: TimeInterval = 0
    private var lastStrokeSent: TimeInterval = 0
    /// Merged rules per bundle id (rebuilt after a config change); keeps dictionary
    /// work off the per-keystroke tap path.
    private var rulesetCache: [String: Ruleset] = [:]
    /// Chord stroke observer for the on-screen trail: (points so far, finished). Called on
    /// the tap thread, at most every `strokeInterval` while drawing; must stay cheap.
    var onChordStroke: ((_ points: [CGPoint], _ finished: Bool) -> Void)?
    /// Runs chord recognition + the action after the tap callback has returned, on a
    /// background queue with a snapshot of the rules (the app sets a global queue;
    /// selftest keeps it synchronous). The swallow/pass decision never waits for it,
    /// and the closure touches no engine state.
    var deferWork: (@escaping () -> Void) -> Void = { $0() }
    /// Every finished stroke / chord+key gesture, with what it was taken for — feeds the
    /// gesture history (手势记录) and the 「未识别」 hint. Called on the recognition queue
    /// (strokes) or the tap thread (keys).
    var onRecognized: ((_ result: Recognition, _ points: [CGPoint], _ app: String) -> Void)?
    var paused = false
    /// When set, ruleset lookup uses this bundle id instead of the frontmost app
    /// (used by --selftest so tests don't depend on what is in front).
    var rulesetOverride: String?
    /// 当前按下的鼠标键：0=左 1=右 2=中 3..7=4..8 键（原版支持 2…8 键组合）
    private var downButtons: Set<Int64> = []
    /// Buttons whose down we swallowed because they joined a chord (every button but
    /// the first). Their up/drag is swallowed too; the first button's down reached the
    /// app, so its up must reach it as well or the app thinks it's still held.
    private var chordSwallowed: Set<Int64> = []
    /// Is mouse button N physically held right now? Used to forget buttons whose
    /// up we never saw (tap briefly disabled …) so a normal click isn't taken for a chord.
    /// Selftest replaces it because synthetic test events don't change the real state.
    var isButtonHeld: (Int64) -> Bool = { b in
        guard let button = CGMouseButton(rawValue: UInt32(b)) else { return true }
        // HID state = the physical button; session state misses presses another tap swallowed.
        return CGEventSource.buttonState(.hidSystemState, button: button)
    }
    private var chordActive = false
    private var chordStart: CGPoint = .zero
    private var chordMoved = false
    private var chordKeyFired: String?
    /// The chord was started by the right button alone (config.gestureButton == "right").
    /// Its down was swallowed; a release without a stroke replays the right click.
    private var rightSolo = false
    private var draining = false
    private var lastPoint: CGPoint = .zero
    private var chordPoints: [CGPoint] = []
    private var cornerAccum: CGFloat = 0
    private var lastCornerFire = Date.distantPast

    // US keyboard keyCode -> character, for two-button + key gestures.
    private static let keyChars: [Int: String] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h",
        34: "i", 38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p",
        12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x",
        16: "y", 6: "z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
        43: ",", 47: ".", 44: "/", 39: "'", 33: "[", 30: "]", 27: "-", 24: "=",
        41: ";", 42: "\\", 50: "`"
    ]

    init(config: Config) {
        self.config = config
    }

    // MARK: - Entry point from the event tap

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Events we synthesized (shortcuts, clicks, replayed right click) must not be re-processed.
        if Actions.isSynthetic(event) { return Unmanaged.passUnretained(event) }
        guard config.enabled, !paused else { return Unmanaged.passUnretained(event) }
        if isBlacklisted() { return Unmanaged.passUnretained(event) }
        let point = event.location
        lastPoint = point

        switch type {
        case .leftMouseDown:
            return buttonDown(0, at: point, event: event)
        case .rightMouseDown:
            return buttonDown(1, at: point, event: event)
        case .otherMouseDown:
            let b = event.getIntegerValueField(.mouseEventButtonNumber)
            return buttonDown(b, at: point, event: event)

        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if chordActive {
                track(point)
                return nil
            }
            // Chord over but a swallowed button is still held: its drags never had a down.
            if !chordSwallowed.isEmpty, chordSwallowed.contains(GestureEngine.dragButton(type, event)) {
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            return buttonUp(0, at: point, event: event)
        case .rightMouseUp:
            return buttonUp(1, at: point, event: event)
        case .otherMouseUp:
            let b = event.getIntegerValueField(.mouseEventButtonNumber)
            return buttonUp(b, at: point, event: event)

        case .keyDown:
            // 只在按住鼠标手势时看字母键（双键 / 右键 + 字母）
            if chordActive {
                let key = chordKey(for: event)
                if let key, let spec = ruleset().gestures["twoKey.key.\(key)"] {
                    Actions.shared.perform(spec)
                    onRecognized?(Recognition(gestureID: "twoKey.key.\(key)", spec: spec, score: 100, via: .key),
                                  [], frontBundleID() ?? "")
                    chordKeyFired = key
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)

        case .scrollWheel:
            handleCornerScroll(at: point, event: event)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Two-button chord

    private enum Button { case left, right }

    private func buttonDown(_ button: Int64, at point: CGPoint,
                            event: CGEvent) -> Unmanaged<CGEvent>? {
        if !chordActive && !downButtons.isEmpty {
            let stale = downButtons.filter { !isButtonHeld($0) }
            if !stale.isEmpty {
                Log.write("dropped stale mouse button(s) \(stale.sorted()) before chord check")
                downButtons.subtract(stale)
                chordSwallowed.subtract(stale)
            }
        }
        downButtons.insert(button)
        if downButtons.count == 1 {
            if button == 1, config.gestureButton == "right", !GestureEngine.isOwnReplay(at: point) {
                // 右键手势：按下先吞，松开时再决定是手势还是普通右键
                beginChord(at: point)
                rightSolo = true
                chordSwallowed.insert(button)
                return nil
            }
            chordStart = point
            return Unmanaged.passUnretained(event)
        }
        // 第二个键按下 → 进入组合手势，吞掉本事件避免右键菜单
        if !chordActive { beginChord(at: point) }
        chordSwallowed.insert(button)
        return nil
    }

    private func buttonUp(_ button: Int64, at point: CGPoint,
                          event: CGEvent) -> Unmanaged<CGEvent>? {
        downButtons.remove(button)
        let downWasSwallowed = chordSwallowed.remove(button) != nil
        // 任意键抬起即结算
        if chordActive { finishChord(released: button) }
        // 按下时被吞的键，抬起也吞；按下已放行的键（第一个键），抬起必须放行
        return downWasSwallowed ? nil : Unmanaged.passUnretained(event)
    }

    private static func dragButton(_ type: CGEventType, _ event: CGEvent) -> Int64 {
        switch type {
        case .leftMouseDragged: return 0
        case .rightMouseDragged: return 1
        default: return event.getIntegerValueField(.mouseEventButtonNumber)
        }
    }

    private func beginChord(at point: CGPoint) {
        chordActive = true
        chordPoints = [point]
        chordStart = point
        chordMoved = false
        chordKeyFired = nil
        rightSolo = false
        draining = false
    }

    private func track(_ point: CGPoint) {
        if distance(from: chordStart, to: point) >= config.minDistance { chordMoved = true }
        if let last = chordPoints.last,
           hypot(point.x - last.x, point.y - last.y) < 2 { return }
        chordPoints.append(point)
        // Right-button mode: no trail until it is really a stroke (a plain right click jitters)
        if rightSolo && !chordMoved { return }
        guard let onChordStroke else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard strokeInterval == 0 || now - lastStrokeSent >= strokeInterval else { return }
        lastStrokeSent = now
        onChordStroke(chordPoints, false)
    }

    private func finishChord(released: Int64) {
        let point = lastPoint
        let moved = chordMoved || distance(from: chordStart, to: point) >= config.minDistance
        let points = chordPoints, start = chordStart
        if rightSolo, !moved, chordKeyFired == nil {
            // 只是单击右键：在按下的位置补发一次右键（带合成标记，不会再进手势）
            deferWork { GestureEngine.replayRightClick(at: start) }
            chordPoints = []
            chordActive = false
            chordMoved = false
            rightSolo = false
            if !downButtons.isEmpty { draining = true }
            return
        }

        if chordKeyFired == nil, moved {
            // Recognition (~1–3 ms) runs after the tap callback returns, off the tap thread,
            // on a snapshot — so neither this release nor the next mouse event waits for DTW.
            let rules = ruleset(), cfg = config, app = frontBundleID() ?? ""
            let report = onRecognized
            deferWork {
                let r = Recognizer.recognize(points: points, rules: rules, config: cfg)
                if r.via == .shape { Log.write("shape gesture score=\(String(format: "%.1f", r.score))") }
                if r.via != .shape && r.via != .direction {
                    Log.write("gesture not run: \(r.via.rawValue) \(r.gestureID ?? "-") score=\(String(format: "%.1f", r.score))")
                }
                if r.fires, let spec = r.spec { Actions.shared.perform(spec) }
                report?(r, points, app)
            }
        }
        if !points.isEmpty { onChordStroke?(points, true) }
        chordPoints = []
        chordActive = false
        chordMoved = false
        chordKeyFired = nil
        rightSolo = false
        if !downButtons.isEmpty { draining = true }
    }

    /// The replayed right click, made to look like a real one: click count 1 and pressure
    /// set (a bare CGEvent has click count 0 — Safari didn't mind, WeChat ignored the click
    /// and showed no menu), tagged so our own tap lets it through.
    static func rightClickEvents(at p: CGPoint) -> [CGEvent] {
        // No event source: a HID-state source wipes eventSourceUserData when posted, the
        // unmarked replay was then swallowed and replayed again — an endless loop that froze
        // WeChat. (`isOwnReplay` is the safety net should a marker ever get lost again.)
        [CGEventType.rightMouseDown, .rightMouseUp].compactMap { type in
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: p, mouseButton: .right) else { return nil }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setDoubleValueField(.mouseEventPressure, value: type == .rightMouseDown ? 1 : 0)
            e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            return e
        }
    }

    /// Runs on the recognition queue (never the tap thread), so the short pause between
    /// press and release — like a real click; some apps drop a menu whose release arrives
    /// in the same instant — costs nothing. Selftest swaps this to record instead of posting.
    static var postRightClick: (CGPoint) -> Void = { p in
        noteReplay(at: p)
        let events = rightClickEvents(at: p)
        for (i, e) in events.enumerated() {
            if i > 0 { usleep(40_000) }
            e.post(tap: .cghidEventTap)
        }
    }
    private static func replayRightClick(at p: CGPoint) { postRightClick(p) }

    /// Safety net against a replay loop: a right press arriving right after our own replay
    /// at the same spot is let through even if its marker got lost on the way.
    private static let replayLock = NSLock()
    private static var lastReplay: (at: TimeInterval, point: CGPoint)?

    static func noteReplay(at p: CGPoint) {
        replayLock.lock(); lastReplay = (ProcessInfo.processInfo.systemUptime, p); replayLock.unlock()
    }

    static func isOwnReplay(at p: CGPoint, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        replayLock.lock(); defer { replayLock.unlock() }
        guard let r = lastReplay, now - r.at < 0.3, hypot(p.x - r.point.x, p.y - r.point.y) < 4 else { return false }
        return true
    }

    private func cocoaPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: screens().mainHeight - p.y)
    }

    /// Screen layout cached for the tap path (NSScreen.screens builds new objects on
    /// every call); refreshed when displays are added, removed or rearranged.
    /// Do one-time setup (screen layout) now, not on the user's first mouse move.
    func warmUp() {
        _ = screens()
        _ = frontBundleID()
    }

    private var screenCache: (mainHeight: CGFloat, cgFrames: [CGRect])?
    private var screenObserver: Any?

    private func screens() -> (mainHeight: CGFloat, cgFrames: [CGRect]) {
        if let c = screenCache { return c }
        if screenObserver == nil {
            // Recomputed on the main thread (NSScreen), then handed to the engine's thread.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                let c = GestureEngine.screenLayout()
                self?.engineQueue { self?.screenCache = c }
            }
        }
        let c = GestureEngine.screenLayout()
        screenCache = c
        return c
    }

    private static func screenLayout() -> (mainHeight: CGFloat, cgFrames: [CGRect]) {
        let frames = NSScreen.screens.map(\.frame)
        let h = frames.first?.maxY ?? 0
        // CGEvent locations use a top-left origin; NSScreen frames use bottom-left.
        return (h, frames.map { CGRect(x: $0.minX, y: h - $0.maxY, width: $0.width, height: $0.height) })
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private func chordKey(for event: CGEvent) -> String? {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard var ch = GestureEngine.keyChars[code] else { return nil }
        let shift = event.flags.contains(.maskShift)
        if ch == "," && shift { ch = "<" }
        return ch
    }

    var isDraining: Bool { draining }
    func endDrain() { draining = false }

    /// Match the drawn stroke against every rule whose gesture maps to a glyph.
    // MARK: - Hot corners + scroll

    private func handleCornerScroll(at point: CGPoint, event: CGEvent) {
        let delta = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        guard delta != 0 else { return }
        let corner = cornerName(for: point)
        guard corner != "none" else { cornerAccum = 0; return }

        // A single physical scroll produces many events. Accumulate them and
        // fire at most once per burst, otherwise a tiny nudge fires 20+ actions.
        // Reversing direction drops what is left of the previous burst: events
        // swallowed by the 0.4 s throttle still pile up here, and without this a quick
        // "turn it back" scroll fired in the *old* direction again.
        if cornerAccum != 0 && (delta > 0) != (cornerAccum > 0) { cornerAccum = 0 }
        cornerAccum += delta
        guard abs(cornerAccum) >= 4 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCornerFire) >= 0.4 else { return }

        let key = "corner.\(corner).\(cornerAccum > 0 ? "up" : "down")"
        if let spec = ruleset().gestures[key] { Actions.shared.perform(spec) }
        lastCornerFire = now
        cornerAccum = 0
    }

    private func cornerName(for point: CGPoint) -> String {
        let size = config.cornerSize
        for f in screens().cgFrames {
            guard f.contains(point) else { continue }
            let left = point.x <= f.minX + size
            let right = point.x >= f.maxX - size
            let top = point.y <= f.minY + size
            let bottom = point.y >= f.maxY - size
            if top && right { return "topRight" }
            if top && left { return "topLeft" }
            if bottom && left { return "bottomLeft" }
            if bottom && right { return "bottomRight" }
        }
        return "none"
    }

    private func isBlacklisted() -> Bool {
        guard let list = config.blacklist, !list.isEmpty else { return false }
        guard let id = frontBundleID() else { return false }
        return list.contains(id)
    }

    private func frontBundleID() -> String? {
        if let rulesetOverride { return rulesetOverride }
        if let cached = frontAppCache { return cached }
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        trackFrontApp(initial: id)
        return id
    }

    /// Front app's bundle id, kept current by activation notifications. Asking
    /// NSWorkspace on every scroll / mouse event cost ~0.1–0.2 ms in the tap.
    private var frontAppCache: String?
    private var frontAppObserver: Any?

    private func trackFrontApp(initial: String?) {
        frontAppCache = initial
        guard frontAppObserver == nil else { return }
        frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.engineQueue { self?.frontAppCache = id }
        }
    }

    // MARK: - Ruleset selection

    /// Active rules for the front app: global (`default`) rules, with the app's own
    /// rules replacing those for the same gesture (原版：App 专属 > 全局). A disabled
    /// app rule switches that gesture off in the app; disabled rules are left out.
    private func ruleset() -> Ruleset {
        let bundleID = frontBundleID() ?? ""
        if let cached = rulesetCache[bundleID] { return cached }
        let rs = GestureEngine.effectiveRules(config, app: bundleID)
        rulesetCache[bundleID] = rs
        return rs
    }

    static func effectiveRules(_ config: Config, app: String) -> Ruleset {
        var g = config.rulesets["default"]?.gestures ?? [:]
        if app != "default", let own = config.rulesets[app]?.gestures {
            g.merge(own) { _, appRule in appRule }
        }
        return Ruleset(gestures: g.filter { $0.value.enabled != false })
    }
}
