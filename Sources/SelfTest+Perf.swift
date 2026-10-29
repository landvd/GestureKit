import Cocoa

// 普通鼠标手势流畅度的回归断言（`--perf` 的精简版，约 1 秒）。
// 识别率用固定随机种子，结果确定；耗时预算放得很宽，只拦明显的退化。
extension SelfTest {
    static func perfChecks() -> [SelfTestCheck] {
        typealias P = PerfBench
        var out: [SelfTestCheck] = []
        let fired = P.Fired()
        let savedObserver = Actions.observer, savedPresenter = Actions.presenter, savedDry = Actions.dryRun
        Actions.dryRun = true
        Actions.observer = { fired.specs.append($0) }
        Actions.presenter = nil
        defer { Actions.observer = savedObserver; Actions.presenter = savedPresenter; Actions.dryRun = savedDry }
        let center = CGPoint(x: 700, y: 450)

        // Per-event cost in the tap callback
        let e = P.engine(P.fullConfig())
        e.warmUp()
        var moved: [UInt64] = [], chord: [UInt64] = []
        for i in 0..<2_000 {
            let m = P.ev(.mouseMoved, CGPoint(x: 300 + Double(i % 800), y: 400), .left)
            let t0 = P.now(); _ = e.handle(type: .mouseMoved, event: m); moved.append(P.now() - t0)
        }
        _ = e.handle(type: .leftMouseDown, event: P.ev(.leftMouseDown, center, .left))
        _ = e.handle(type: .rightMouseDown, event: P.ev(.rightMouseDown, center, .right))
        for i in 0..<2_000 {
            let a = Double(i) * 0.05
            let d = P.ev(.leftMouseDragged, CGPoint(x: 700 + 200 * cos(a), y: 450 + 200 * sin(a)), .left)
            let t0 = P.now(); _ = e.handle(type: .leftMouseDragged, event: d); chord.append(P.now() - t0)
        }
        _ = e.handle(type: .leftMouseUp, event: P.ev(.leftMouseUp, center, .left))
        _ = e.handle(type: .rightMouseUp, event: P.ev(.rightMouseUp, center, .right))
        let m = P.micros(moved), c = P.micros(chord)
        out.append(SelfTestCheck(name: "perf: mouse-move cost in tap (p99 < 100µs)", ok: m.p99 < 100,
                                 detail: String(format: "p99 %.1fµs", m.p99)))
        out.append(SelfTestCheck(name: "perf: chord-drag cost in tap (p99 < 100µs)", ok: c.p99 < 100,
                                 detail: String(format: "p99 %.1fµs", c.p99)))

        // Release (recognition) with every glyph rule present
        var rng = P.RNG(state: 7)
        let e2 = P.engine(P.fullConfig())
        _ = P.stroke(e2, P.render("S", size: 250, aspect: 1, rotateDeg: 0, jitter: 1, step: 8,
                                  origin: center, rng: &rng), fired: fired)          // warm-up
        var rel: [UInt64] = []
        for _ in 0..<10 {
            rel.append(P.stroke(e2, P.render("S", size: 250, aspect: 1, rotateDeg: 0, jitter: 1, step: 2,
                                             origin: center, rng: &rng), fired: fired).1)
        }
        let r = P.micros(rel)
        out.append(SelfTestCheck(name: "perf: release/recognition (max < 20ms)", ok: r.max < 20_000,
                                 detail: String(format: "max %.2fms", r.max / 1000)))

        // Recognition stability (deterministic): "normal" strokes, 10 per glyph
        var hits = 0, total = 0
        var rng2 = P.RNG(state: 42)
        for (g, _) in P.glyphIDs {
            for _ in 0..<10 {
                let pts = P.render(g, size: rng2.range(100, 300), aspect: 1 + rng2.range(-0.2, 0.2),
                                   rotateDeg: rng2.range(-10, 10), jitter: 2.5, step: rng2.range(3, 25),
                                   origin: center, rng: &rng2)
                total += 1
                if P.isHit(g, P.stroke(e2, pts, fired: fired).0) { hits += 1 }
            }
        }
        let rate = Double(hits) / Double(total) * 100
        out.append(SelfTestCheck(name: "perf: glyph hit rate, normal strokes (≥ 95%)", ok: rate >= 95,
                                 detail: String(format: "%.1f%%", rate)))

        // Actions never hold the tap
        let a = Actions()
        a.executor = { work in Actions.workQueue.async { usleep(50_000); work() } }
        Actions.dryRun = false
        Actions.observer = nil
        var held: UInt64 = 0
        for _ in 0..<5 {
            let t0 = P.now()
            a.perform(ActionSpec(type: "nothing", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil))
            held = max(held, P.now() - t0)
        }
        Actions.workQueue.sync {}
        out.append(SelfTestCheck(name: "perf: tap is not held by a slow action (< 5ms)", ok: held < 5_000_000,
                                 detail: String(format: "%.2fms", Double(held) / 1e6)))
        return out
    }
}
