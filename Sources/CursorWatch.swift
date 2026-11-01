import Cocoa

/// Diagnostic: logs sudden cursor jumps, to find out who moves the cursor when it "centres
/// itself". Samples the position 10 times a second off the main thread and off the tap;
/// logs only what looks like a jump (`cursor jump:` in the log), plus display changes and
/// wake, which macOS may answer by moving the cursor. Coordinates and the front app's bundle
/// id only. Compare with the `action type=` lines around it in the log.
enum CursorWatch {
    static let interval: TimeInterval = 0.1
    /// A landing this close to a display's centre, after moving this far, is a centring.
    static let centerTolerance: CGFloat = 3
    static let centerMinMove: CGFloat = 200
    /// Anything further within one sample is unusually fast for a hand; a hard flick may log too.
    static let hugeMove: CGFloat = 500
    /// A big move out of a still cursor: a hand accelerates, a program teleports.
    static let teleportMove: CGFloat = 150
    static let stillBelow: CGFloat = 3
    static let minLogGap: TimeInterval = 1

    enum Jump: String { case center, huge, teleport }

    static func classify(before: CGPoint? = nil, from: CGPoint, to: CGPoint, centers: [CGPoint]) -> Jump? {
        let moved = hypot(to.x - from.x, to.y - from.y)
        if moved >= centerMinMove,
           centers.contains(where: { abs($0.x - to.x) <= centerTolerance && abs($0.y - to.y) <= centerTolerance }) {
            return .center
        }
        if moved >= hugeMove { return .huge }
        if moved >= teleportMove, let before, hypot(from.x - before.x, from.y - before.y) < stillBelow { return .teleport }
        return nil
    }

    /// Display centres in CG coordinates (top-left origin). Main thread (NSScreen).
    static func displayCenters() -> [CGPoint] {
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.map { CGPoint(x: $0.frame.midX, y: h - $0.frame.midY) }
    }

    private static let queue = DispatchQueue(label: "gesturekit.cursorwatch", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static var observers: [NSObjectProtocol] = []
    private static var centers: [CGPoint] = []                 // on `queue`
    private static var last: CGPoint?                          // on `queue`
    private static var beforeLast: CGPoint?                    // on `queue`
    private static var lastLog: TimeInterval = 0               // on `queue`

    /// Main thread.
    static func start() {
        guard timer == nil else { return }
        let initial = displayCenters()
        Log.write("cursor watch: started, centers=\(initial.map(text))")
        queue.async { centers = initial }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            let c = displayCenters()
            Log.write("cursor watch: display layout changed, \(c.count) display(s), centers=\(c.map(text))")
            queue.async { centers = c }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Log.write("cursor watch: system woke")
        })
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { sample() }
        timer = t
        t.resume()
    }

    private static func sample() {
        guard let now = CGEvent(source: nil)?.location else { return }
        defer { beforeLast = last; last = now }
        guard let last, let jump = classify(before: beforeLast, from: last, to: now, centers: centers) else { return }
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastLog >= minLogGap else { return }
        lastLog = time
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
        Log.write("cursor jump: \(jump.rawValue) \(text(last)) → \(text(now)) front=\(front)")
    }

    /// Tells the system where the cursor really is after a stroke whose drags were swallowed.
    /// Without this the cursor sometimes snapped back to where the stroke began. Off the tap thread.
    static func resync(to point: CGPoint) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                              mouseButton: .left) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
        e.post(tap: .cghidEventTap)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
            let now = CGEvent(source: nil)?.location ?? point
            Log.write("cursor resync: end=\(text(point)) after150ms=\(text(now))")
        }
    }

    /// One line per finished stroke: does the event stream itself contain a jump, and does
    /// the real cursor agree with where the stroke ended? Off the tap thread.
    static func logStroke(_ points: [CGPoint]) {
        guard let first = points.first, let end = points.last else { return }
        var maxStep: CGFloat = 0
        for (a, b) in zip(points, points.dropFirst()) { maxStep = max(maxStep, hypot(b.x - a.x, b.y - a.y)) }
        let now = CGEvent(source: nil)?.location ?? end
        Log.write("cursor stroke: \(text(first)) → \(text(end)) maxStep=\(Int(maxStep)) cursorNow=\(text(now))")
    }

    private static func text(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
}
