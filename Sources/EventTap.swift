import Cocoa

/// A thread of its own for the event tap. Every mouse event of the whole system waits
/// for the tap callback; on the main thread it also waited for whatever the settings
/// window (SwiftUI layout), the trail or the HUD were doing, so the cursor stuttered.
/// The engine's state lives on this thread only — other threads hand work over with
/// `perform`, and the engine hands UI work back to the main queue.
final class TapThread {
    static let shared = TapThread()

    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let t = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once: keep a port in it.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            self.ready.signal()
            while true { CFRunLoopRun() }
        }
        t.name = "gesturekit.tap"
        t.qualityOfService = .userInteractive          // mouse input: highest priority
        t.start()
        ready.wait()
    }

    var loop: CFRunLoop { runLoop! }

    /// Run `block` on the tap thread (after the current callback, if called from there).
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Run `block` on the tap thread and wait for it (main-thread setup only).
    func sync(_ block: @escaping () -> Void) {
        if CFRunLoopGetCurrent() === runLoop { block(); return }
        let done = DispatchSemaphore(value: 0)
        perform { block(); done.signal() }
        done.wait()
    }
}

/// Owns the global event tap. The tap is active (.defaultTap) so a two-button
/// chord can suppress the stray right-click that would otherwise open a menu.
/// Its run-loop source lives on `TapThread`, not the main thread.
final class EventTap {

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var engine: GestureEngine?
    var onTapDisabled: (() -> Void)?

    /// 中键与 4…8 键（otherMouse*）也要进来：单独按时引擎放行，组合手势时才吞。
    static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .mouseMoved,        // 窗口吸附：碰边滑出
            .keyDown, .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    }()

    @discardableResult
    func start(engine: GestureEngine) -> Bool {
        stop()
        self.engine = engine

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: EventTap.eventMask,
            callback: gestureTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(EventTap.loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        MouseButtonFeed.tapRunning = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(EventTap.loop, source, .commonModes) }
        tap = nil
        source = nil
        MouseButtonFeed.tapRunning = false
    }

    func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    var isRunning: Bool { tap != nil }

    /// Diagnostic only: `GK_TAP_ON_MAIN=1` puts the tap back on the main thread (the old
    /// setup) so `--tap-isolation-test` can show the difference.
    static let loop: CFRunLoop = ProcessInfo.processInfo.environment["GK_TAP_ON_MAIN"] == "1"
        ? CFRunLoopGetMain() : TapThread.shared.loop
}

private func gestureTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        tap.onTapDisabled?()
        return Unmanaged.passUnretained(event)
    }
    if TapIsolationTest.active { TapIsolationTest.record(event) }
    // 设置页「按键识别」只观察（未打开该页时只是一次布尔判断）
    if MouseButtonFeed.isActive { MouseButtonFeed.publish(type: type, event: event) }
    guard TapStats.enabled else { return EventTap.dispatch(tap.engine, type: type, event: event) }
    let t0 = DispatchTime.now().uptimeNanoseconds
    let out = EventTap.dispatch(tap.engine, type: type, event: event)
    TapStats.record(type, DispatchTime.now().uptimeNanoseconds - t0)
    return out
}

extension EventTap {
    /// Engine verdict → tap return value. `nil` from the engine means swallow and must
    /// stay `nil`: `engine?.handle(...) ?? pass` flattens that nil into "pass" (that bug
    /// let every chord's right-click through). Only a missing engine passes.
    static func dispatch(_ engine: GestureEngine?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let engine else { return Unmanaged.passUnretained(event) }
        return engine.handle(type: type, event: event)
    }
}

/// `GK_PERF=1`: time every tap callback and log a latency summary every 10 s.
/// The callback runs on the tap thread and holds the event until it returns, so
/// these numbers are exactly the delay GestureKit adds to the system's mouse input.
enum TapStats {
    static let enabled = ProcessInfo.processInfo.environment["GK_PERF"] == "1"
    private static var samples: [CGEventType.RawValue: [UInt64]] = [:]
    private static var lastReport = DispatchTime.now().uptimeNanoseconds

    static func record(_ type: CGEventType, _ ns: UInt64) {
        samples[type.rawValue, default: []].append(ns)
        let now = DispatchTime.now().uptimeNanoseconds
        // `lastReport` is lazily initialised (possibly after `now` was read): never subtract unsigned blindly.
        guard now > lastReport, now - lastReport > 10_000_000_000 else { return }
        lastReport = now
        Log.write(report())
        samples.removeAll(keepingCapacity: true)
    }

    static func report() -> String {
        let names: [CGEventType.RawValue: String] = [
            CGEventType.mouseMoved.rawValue: "moved", CGEventType.leftMouseDragged.rawValue: "lDrag",
            CGEventType.rightMouseDragged.rawValue: "rDrag", CGEventType.leftMouseDown.rawValue: "lDown",
            CGEventType.leftMouseUp.rawValue: "lUp", CGEventType.rightMouseDown.rawValue: "rDown",
            CGEventType.rightMouseUp.rawValue: "rUp", CGEventType.scrollWheel.rawValue: "scroll",
            CGEventType.keyDown.rawValue: "key"]
        var parts = samples.sorted { $0.key < $1.key }.map { k, v -> String in
            let s = v.sorted()
            func us(_ q: Double) -> Double { Double(s[Int(Double(s.count - 1) * q)]) / 1000 }
            let slow = v.filter { $0 > 1_000_000 }.count
            return String(format: "%@ n=%d p50=%.0fµs p99=%.0fµs max=%.0fµs >1ms=%d",
                          names[k] ?? "t\(k)", v.count, us(0.5), us(0.99), us(1), slow)
        }
        let (stalls, worst) = MainStallWatch.take()
        parts.append(String(format: "main stalls>30ms=%d worst=%.0fms", stalls, worst))
        return "perf tap: " + parts.joined(separator: " | ")
    }
}

/// `GK_PERF=1`: how long the main thread (settings UI, trail, HUD) is blocked. Since the
/// tap moved to `TapThread` such a stall only delays the UI, not the cursor; the tap's
/// own latency is the per-event numbers above.
enum MainStallWatch {
    private static let lock = NSLock()
    private static var stalls = 0
    private static var worst: Double = 0

    static func start() {
        guard TapStats.enabled else { return }
        Thread.detachNewThread {
            while true {
                let sent = DispatchTime.now().uptimeNanoseconds
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                sem.wait()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                if ms > 30 {
                    lock.lock(); stalls += 1; worst = max(worst, ms); lock.unlock()
                    Log.write(String(format: "perf: main thread stalled %.0f ms", ms))
                }
                usleep(20_000)
            }
        }
    }

    static func take() -> (Int, Double) {
        lock.lock(); defer { lock.unlock() }
        let r = (stalls, worst); stalls = 0; worst = 0
        return r
    }
}
