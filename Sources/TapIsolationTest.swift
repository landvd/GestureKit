import Cocoa

/// `--tap-isolation-test`: proves the event tap no longer waits for the main thread.
/// While the main thread is blocked 5 × 400 ms (what a slow settings-window layout
/// does, exaggerated), a background thread posts 1000 mouse-moved events at the
/// cursor's own position (it doesn't move), each stamped with its send time. The tap
/// callback measures send → callback. With the tap on the main thread those events
/// waited up to 400 ms; on `TapThread` they should stay at about a millisecond.
/// Exit code 0 = pass (max < 20 ms).
enum TapIsolationTest {
    /// High byte tag in eventSourceUserData; the low 56 bits carry the send time (ns).
    static let tag: Int64 = 0x7A << 56
    static var active = false
    private static var latencies: [UInt64] = []          // tap thread only

    /// From the tap callback (tap thread).
    static func record(_ event: CGEvent) {
        let ud = event.getIntegerValueField(.eventSourceUserData)
        guard ud & (0xFF << 56) == tag else { return }
        let sent = UInt64(ud & ~(0xFF << 56))
        let now = DispatchTime.now().uptimeNanoseconds
        if now > sent { latencies.append(now - sent) }
    }

    static func run(done: @escaping (Int32) -> Void) {
        active = true
        Thread.detachNewThread {
            let at = CGEvent(source: nil)?.location ?? .zero
            // Main thread: 5 × 400 ms blocks, 200 ms apart.
            DispatchQueue.global().async {
                for _ in 0..<5 {
                    DispatchQueue.main.async { usleep(400_000) }
                    usleep(600_000)
                }
            }
            for _ in 0..<1000 {
                let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)!
                e.setIntegerValueField(.eventSourceUserData, value: tag | Int64(DispatchTime.now().uptimeNanoseconds))
                e.post(tap: .cghidEventTap)
                usleep(2_000)
            }
            usleep(300_000)
            TapThread.shared.sync {
                let s = latencies.sorted()
                let ms = { (q: Double) -> Double in s.isEmpty ? -1 : Double(s[Int(Double(s.count - 1) * q)]) / 1e6 }
                let line = String(format: "tap isolation: %d/1000 events seen, p50 %.2f ms, p99 %.2f ms, max %.2f ms (main thread blocked 5 × 400 ms)",
                                  s.count, ms(0.5), ms(0.99), ms(1))
                print(line); Log.write(line)
                let ok = s.count > 900 && ms(1) < 20
                print(ok ? "PASS  cursor events are not held up by the main thread" : "FAIL  tap still waits for the main thread")
                active = false
                DispatchQueue.main.async { done(ok ? 0 : 1) }
            }
        }
    }
}
