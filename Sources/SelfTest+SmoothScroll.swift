import Cocoa

// 平滑滚动：滑动曲线、放行条件、与边角滚轮的关系（不发真实滚轮事件）。
extension SelfTest {
    static func smoothScrollChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        func wheel(_ lines: Int32, flags: CGEventFlags = [], at p: CGPoint = CGPoint(x: 700, y: 500),
                   pixels: Bool = false) -> CGEvent {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line,
                            wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
            e.flags = flags
            e.location = p
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: pixels ? 1 : 0)
            return e
        }
        func scroller() -> (SmoothScroller, () -> (x: Int, y: Int, posts: Int)) {
            let s = SmoothScroller()
            s.perform = { $0() }
            s.autoTick = false
            var x = 0, y = 0, n = 0
            s.post = { dx, dy in x += Int(dx); y += Int(dy); n += 1 }
            return (s, { (x, y, n) })
        }
        func drain(_ s: SmoothScroller) { var i = 0; while !s.isIdle && i < 2000 { s.tick(); i += 1 } }

        // 曲线：按 Safari 里实测的目标（一格约 65px、约 0.45 秒滑停，连续滚每格约 88px）
        let defaults = SmoothScroller.Settings()
        let oneNotch = SmoothScroller.delta(of: wheel(-1), settings: defaults)!.dy
        do {
            let (s, total) = scroller()
            var firstSteps: [Int] = []
            s.post = { _, dy in firstSteps.append(Int(dy)) }
            s.add(dx: 0, dy: oneNotch); var frames = 0
            while !s.isIdle && frames < 2000 { s.tick(); frames += 1 }
            let sum = firstSteps.reduce(0, +), ms = Double(frames) / 120 * 1000
            check("smooth: one notch glides about 65px in about 0.4s",
                  (-80 ... -60).contains(sum) && (300...500).contains(ms), "\(sum)px \(ms)ms")
            let peak = firstSteps.map(abs).max() ?? 0
            check("smooth: eases in (starts slower than its peak)", abs(firstSteps[0]) < peak, "\(firstSteps.prefix(8))")
            _ = total
        }
        do {
            let (s, total) = scroller()
            for i in 0..<10 { s.add(dx: 0, dy: oneNotch); for _ in 0..<5 { s.tick() }; _ = i }
            drain(s)
            check("smooth: ten fast notches go about 860px", (-950 ... -780).contains(total().y), "\(total())")
        }
        do {
            let (s, total) = scroller()
            s.add(dx: 37, dy: 0); drain(s)
            let (s2, total2) = scroller()
            s2.add(dx: 0, dy: 37); drain(s2)
            check("smooth: axes behave alike", total().x == total2().y && total().x > 0, "\(total()) \(total2())")
        }
        do {
            let (s, total) = scroller()
            s.add(dx: 0, dy: 100); for _ in 0..<20 { s.tick() }; let sent = total().y
            s.add(dx: 0, dy: -100); drain(s)
            check("smooth: reversing cancels what is in flight", sent > 0 && total().y < sent, "\(sent) \(total())")
        }
        do {
            let (s, _) = scroller()
            s.add(dx: 0, dy: 1_000_000)
            check("smooth: pending is capped", s.pendingY == SmoothScroller.maxPending)
        }
        let plain = SmoothScroller.delta(of: wheel(3), settings: defaults)
        check("smooth: discrete wheel is taken", plain != nil && plain!.dy != 0)
        check("smooth: small notches still move the minimum distance",
              abs(oneNotch) == defaults.step * defaults.gain, "\(oneNotch)")
        check("smooth: step and gain set the notch distance",
              abs(SmoothScroller.delta(of: wheel(-1), settings: .init(step: 50, gain: 2))!.dy) == 100
                && abs(SmoothScroller.delta(of: wheel(-1), settings: .init(step: 90, gain: 1))!.dy) == 90)
        check("smooth: settings are limited to the slider ranges",
              SmoothScroller.Settings(step: 0, gain: 99, duration: 9) == .init(step: 1, gain: 10, duration: 1))
        check("smooth: defaults come from an empty config",
              SmoothScroller.Settings(Config.defaultConfig) == defaults
                && defaults.step == 32 && defaults.gain == 2.625 && defaults.duration == 0.4)
        do {
            func glide(_ duration: CGFloat) -> (px: Int, frames: Int) {
                let (s, total) = scroller()
                s.add(dx: 0, dy: 300, duration: duration)
                var frames = 0
                while !s.isIdle && frames < 5000 { s.tick(); frames += 1 }
                return (total().y, frames)
            }
            let short = glide(0.2), long = glide(0.8)
            check("smooth: duration changes the time, not the distance",
                  long.frames > short.frames * 3 && abs(long.px - short.px) <= 3, "\(short) \(long)")
        }
        check("smooth: trackpad / continuous passes", SmoothScroller.delta(of: wheel(3, pixels: true), settings: defaults) == nil)
        check("smooth: modifiers pass",
              [CGEventFlags.maskShift, .maskCommand, .maskControl, .maskAlternate]
                .allSatisfy { SmoothScroller.delta(of: wheel(3, flags: $0), settings: defaults) == nil })

        // MARK: 引擎
        func engine(enabled: Bool? = nil, smoother: SmoothScroller?) -> GestureEngine {
            var c = Config.defaultConfig; c.smoothScrollEnabled = enabled
            let e = GestureEngine(config: c)
            e.rulesetOverride = "selftest.none"
            e.isButtonHeld = { _ in true }
            e.smoother = smoother
            return e
        }
        do {
            let (s, _) = scroller()
            check("smooth: engine swallows and animates a wheel notch",
                  engine(smoother: s).handle(type: .scrollWheel, event: wheel(3)) == nil && !s.isIdle)
        }
        do {
            let (s, _) = scroller()
            check("smooth: switched off passes",
                  engine(enabled: false, smoother: s).handle(type: .scrollWheel, event: wheel(3)) != nil && s.isIdle)
            check("smooth: no scroller (selftest default) passes",
                  engine(smoother: nil).handle(type: .scrollWheel, event: wheel(3)) != nil)
        }
        do {
            let (s, _) = scroller()
            let e = engine(smoother: s)
            let marked = wheel(3); marked.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            check("smooth: our own scroll events are not smoothed again",
                  e.handle(type: .scrollWheel, event: marked) != nil && s.isIdle)
        }
        do {
            let (s, _) = scroller()
            let e = engine(smoother: s)
            let corner = wheel(3, at: CGPoint(x: 0, y: 0))
            check("smooth: hot corners keep the raw wheel", e.handle(type: .scrollWheel, event: corner) != nil && s.isIdle)
        }
        do {
            let (s, _) = scroller()
            var c = Config.defaultConfig; c.blacklist = ["selftest.none"]
            let e = GestureEngine(config: c)
            e.rulesetOverride = "selftest.none"
            e.smoother = s
            check("smooth: blacklisted app passes", e.handle(type: .scrollWheel, event: wheel(3)) != nil && s.isIdle)
        }
        return out
    }
}
