import Cocoa

/// Smooth scrolling for discrete mouse wheels.
///
/// A wheel notch is swallowed and re-emitted as small pixel deltas at 120 Hz. The position
/// follows the target through two low-pass stages, so a scroll eases in, glides and eases
/// out; each notch moves at least `Settings.step` × `Settings.gain`. The defaults were tuned
/// against page motion measured in Safari. Continuous scrolls (trackpad, Magic Mouse)
/// are never touched. Holding ⌃/⌥/⌘ (zoom…) or ⇧ (horizontal scroll) passes the raw event.
///
/// Threading: `delta` runs on the tap thread and only reads the event; all other state lives
/// on the scroller's own queue, so neither a stalled main thread nor this animation can
/// hold up the tap.
final class SmoothScroller {
    /// The three user settings (通用设置 → 滚动), limited to what the sliders offer.
    struct Settings: Equatable {
        static let stepRange = 1.0...100.0, gainRange = 1.0...10.0, durationRange = 0.1...1.0
        static let defaultStep = 32.0, defaultGain = 2.625, defaultDuration = 0.4

        var step: CGFloat                                      // shortest notch, points, before gain
        var gain: CGFloat
        var duration: CGFloat                                  // seconds one notch roughly glides

        init(step: Double? = nil, gain: Double? = nil, duration: Double? = nil) {
            func limit(_ v: Double, _ r: ClosedRange<Double>) -> CGFloat { CGFloat(min(max(v, r.lowerBound), r.upperBound)) }
            self.step = limit(step ?? Self.defaultStep, Self.stepRange)
            self.gain = limit(gain ?? Self.defaultGain, Self.gainRange)
            self.duration = limit(duration ?? Self.defaultDuration, Self.durationRange)
        }

        init(_ c: Config) {
            self.init(step: c.smoothScrollStep, gain: c.smoothScrollGain, duration: c.smoothScrollDuration)
        }
    }

    // Curve at the default duration; a longer duration slows all three alike, so the
    // distance stays the same.
    static let leadShare: CGFloat = 0.038                      // first stage, share per frame
    static let followShare: CGFloat = 0.26                     // second stage, share per frame
    static let stopBelow: CGFloat = 0.6                        // px per frame: glide is over
    static let settleFrames = 7                                // no stop right after a notch
    static let maxPending: CGFloat = 6000
    static let frameInterval: TimeInterval = 1.0 / 120

    /// Emits one synthetic scroll (pixels). Replaced in tests.
    var post: (_ dx: Int32, _ dy: Int32) -> Void = SmoothScroller.postScroll
    /// Runs state changes on the scroller's queue. Selftest: inline.
    var perform: (@escaping () -> Void) -> Void
    /// false = caller drives `tick()` (selftest); true = 120 Hz timer.
    var autoTick = true

    private let queue: DispatchQueue
    /// One scroll axis, in pixels from where the glide began.
    private struct Axis {
        var target: CGFloat = 0, lead: CGFloat = 0, position: CGFloat = 0, carry: CGFloat = 0
        var framesSinceInput = 0
        var rate: CGFloat = 1                                  // default duration / duration
        var active = false

        var pending: CGFloat { target - position }

        mutating func add(_ delta: CGFloat, rate newRate: CGFloat) {
            guard delta != 0 else { return }
            // Reversing direction cancels whatever is still in flight.
            if active, (delta > 0) != (pending > 0) { self = Axis() }
            let cap = SmoothScroller.maxPending
            target = position + max(-cap, min(cap, pending + delta))
            framesSinceInput = 0
            rate = newRate
            active = true
        }

        /// One frame → whole pixels to emit.
        mutating func step() -> Int32 {
            guard active else { return 0 }
            lead += (target - lead) * min(1, SmoothScroller.leadShare * rate)
            let move = (lead - position) * min(1, SmoothScroller.followShare * rate)
            position += move
            framesSinceInput += 1
            let out = carry + move
            let whole = out.rounded(.towardZero)
            carry = out - whole
            if framesSinceInput > SmoothScroller.settleFrames, abs(move) < SmoothScroller.stopBelow * rate { self = Axis() }
            return Int32(whole)
        }
    }

    private var x = Axis(), y = Axis()
    private var timer: DispatchSourceTimer?

    var isIdle: Bool { !x.active && !y.active }
    var pendingY: CGFloat { y.pending }

    init() {
        let q = DispatchQueue(label: "gesturekit.smoothscroll", qos: .userInteractive)
        queue = q
        perform = { q.async(execute: $0) }
    }

    /// The distance to animate; nil = leave this event alone.
    static func delta(of event: CGEvent, settings: Settings) -> (dx: CGFloat, dy: CGFloat)? {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty
        else { return nil }
        var dy = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        var dx = CGFloat(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        if dy == 0 && dx == 0 {
            // Some drivers only fill the line delta.
            dy = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
            dx = CGFloat(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
        }
        guard dy != 0 || dx != 0 else { return nil }
        func notch(_ v: CGFloat) -> CGFloat {
            v == 0 ? 0 : (v < 0 ? -1 : 1) * max(abs(v), settings.step) * settings.gain
        }
        return (notch(dx), notch(dy))
    }

    func add(dx: CGFloat, dy: CGFloat, duration: CGFloat = CGFloat(Settings.defaultDuration)) {
        let rate = CGFloat(Settings.defaultDuration) / duration
        perform { [self] in
            x.add(dx, rate: rate)
            y.add(dy, rate: rate)
            if autoTick { startTimer() }
        }
    }

    /// One animation frame. Internal so tests can step it.
    func tick() {
        let outX = x.step(), outY = y.step()
        if isIdle {
            timer?.cancel()
            timer = nil
        }
        if outX != 0 || outY != 0 { post(outX, outY) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: SmoothScroller.frameInterval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private static func postScroll(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
        e.post(tap: .cghidEventTap)
    }
}
