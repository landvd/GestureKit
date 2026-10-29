import Cocoa

/// `--perf`: smoothness benchmark for ordinary-mouse gestures.
///
///   P1  per-event cost inside the tap callback (mouse moved / drag / drag in a chord)
///   P2  release cost: shape recognition + dispatch, by stroke length and rule count
///   P3  recognition stability: every built-in glyph drawn with size / aspect /
///       rotation / jitter / sampling-speed variations → hit rate, confusions
///   P4  trail cost per event for long strokes
///   P5  main-thread blocking of actions on the gesture path (read-only probes)
///
/// Deterministic (seeded RNG). Prints a table with budgets; exit code 1 if any
/// budget is missed. Never posts events or runs real actions (dry-run).
enum PerfBench {

    struct Result { let name: String; let value: String; let budget: String; let ok: Bool }

    // MARK: - Helpers

    /// SplitMix64 — reproducible noise.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
        mutating func gauss() -> Double {                       // Box–Muller
            let u = max(unit(), 1e-12), v = unit()
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func micros(_ ns: [UInt64]) -> (p50: Double, p99: Double, max: Double) {
        let s = ns.sorted()
        func at(_ q: Double) -> Double { Double(s[min(s.count - 1, Int(Double(s.count - 1) * q))]) / 1000 }
        return (at(0.5), at(0.99), Double(s.last ?? 0) / 1000)
    }

    static func engine(_ config: Config) -> GestureEngine {
        let e = GestureEngine(config: config)
        e.rulesetOverride = "perf.none"
        e.isButtonHeld = { _ in true }
        return e
    }

    static func ev(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
    }

    /// Default rules plus one rule per built-in glyph (the realistic "many rules" case).
    static func fullConfig() -> Config {
        var c = Config.defaultConfig
        for (g, id) in glyphIDs {
            var s = ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: g, op: "missionControl", delta: nil)
            s.note = g
            c.rulesets["default"]!.gestures[id] = s
        }
        return c
    }

    static let glyphIDs: [(String, String)] = [
        ("←", "twoKey.left"), ("→", "twoKey.right"), ("↑", "twoKey.up"), ("↓", "twoKey.down"),
        ("↖", "twoKey.upLeft"), ("↗", "twoKey.upRight"), ("↙", "twoKey.downLeft"), ("↘", "twoKey.downRight"),
        ("↑←", "twoKey.upThenLeft"), ("↑→", "twoKey.upThenRight"), ("↓←", "twoKey.downThenLeft"), ("↓→", "twoKey.downThenRight"),
        ("↑↓", "twoKey.upThenDown"),
        ("<", "twoKey.key.<"), (">", "twoKey.key.>"),
    ] + "AVTFLZCOSMNUWH".map { (String($0), "twoKey.key.\($0.lowercased())") }

    /// Glyphs with identical templates: drawing either one counts as a hit for both.
    static let sameShape: [String: String] = ["F": "↑→", "↑→": "F", "L": "↓→", "↓→": "L"]
    static func isHit(_ drawn: String, _ got: String?) -> Bool { got == drawn || (got != nil && sameShape[drawn] == got) }

    /// Polyline → points every `step` pt (what a mouse at that speed would report).
    static func sample(_ poly: [CGPoint], step: CGFloat) -> [CGPoint] {
        var out = [poly[0]]
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for k in 1...n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    /// One "human" rendition of a glyph template (template space 0…100, CG y-down).
    static func render(_ glyph: String, size: Double, aspect: Double, rotateDeg: Double,
                       jitter: Double, step: Double, origin: CGPoint, rng: inout RNG) -> [CGPoint] {
        let t = GlyphLibrary.template(for: glyph)!
        let r = rotateDeg * .pi / 180
        let poly = t.map { p -> CGPoint in
            let x = (Double(p.x) - 50) / 100 * size * aspect, y = (Double(p.y) - 50) / 100 * size
            return CGPoint(x: origin.x + CGFloat(x * cos(r) - y * sin(r)), y: origin.y + CGFloat(x * sin(r) + y * cos(r)))
        }
        return sample(poly, step: CGFloat(step)).map {
            CGPoint(x: $0.x + CGFloat(rng.gauss() * jitter), y: $0.y + CGFloat(rng.gauss() * jitter))
        }
    }

    /// Feed one chord stroke; returns (label fired, ns spent in the release event).
    /// Actions seen by the observer (a class, so the observer and the caller can share it).
    final class Fired { var specs: [ActionSpec] = [] }

    static func stroke(_ e: GestureEngine, _ pts: [CGPoint], fired: Fired) -> (String?, UInt64) {
        fired.specs.removeAll()
        _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, pts[0], .left))
        _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, pts[0], .right))
        for p in pts.dropFirst() { _ = e.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, p, .left)) }
        let up = ev(.leftMouseUp, pts.last!, .left)
        let t0 = now()
        _ = e.handle(type: .leftMouseUp, event: up)
        let dt = now() - t0
        _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, pts.last!, .right))
        return (fired.specs.first?.note ?? fired.specs.first?.label, dt)
    }

    // MARK: - Run

    static func run() -> Int32 {
        Actions.dryRun = true
        let fired = Fired()
        Actions.observer = { fired.specs.append($0) }
        Actions.presenter = nil
        L10n.override = "zh"
        var results: [Result] = []
        func add(_ n: String, _ v: String, _ b: String, _ ok: Bool) { results.append(Result(name: n, value: v, budget: b, ok: ok)) }
        let center = CGPoint(x: 700, y: 450)

        // P1 — per-event cost
        do {
            let e = engine(fullConfig())
            e.warmUp()                                   // as AppDelegate does at launch
            var moved: [UInt64] = [], drag: [UInt64] = [], chordDrag: [UInt64] = []
            for i in 0..<20_000 {
                let p = CGPoint(x: 300 + Double(i % 800), y: 300 + Double(i % 300))
                let m = ev(.mouseMoved, p, .left)
                let t0 = now(); _ = e.handle(type: .mouseMoved, event: m); moved.append(now() - t0)
            }
            _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, center, .left))
            for i in 0..<20_000 {
                let d = ev(.leftMouseDragged, CGPoint(x: 300 + Double(i % 800), y: 450), .left)
                let t0 = now(); _ = e.handle(type: .leftMouseDragged, event: d); drag.append(now() - t0)
            }
            _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, center, .left))
            // chord: long stroke, worst case for anything O(n) per event
            _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, center, .left))
            _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, center, .right))
            for i in 0..<5_000 {
                let a = Double(i) * 0.05
                let d = ev(.leftMouseDragged, CGPoint(x: 700 + 200 * cos(a), y: 450 + 200 * sin(a)), .left)
                let t0 = now(); _ = e.handle(type: .leftMouseDragged, event: d); chordDrag.append(now() - t0)
            }
            _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, center, .left))
            _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, center, .right))
            var scroll: [UInt64] = []
            for i in 0..<5_000 {
                let sc = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
                sc.location = CGPoint(x: 400 + Double(i % 600), y: 400)       // away from corners: the common case
                let t0 = now(); _ = e.handle(type: .scrollWheel, event: sc); scroll.append(now() - t0)
            }
            // Same, but resolving the real front app (no rulesetOverride): the path users hit.
            let live = GestureEngine(config: fullConfig())
            live.warmUp()
            var liveScroll: [UInt64] = []
            for i in 0..<5_000 {
                let sc = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
                sc.location = CGPoint(x: 400 + Double(i % 600), y: 400)
                let t0 = now(); _ = live.handle(type: .scrollWheel, event: sc); liveScroll.append(now() - t0)
            }
            for (name, xs) in [("P1 mouseMoved", moved), ("P1 drag (no chord)", drag), ("P1 drag in chord (5000 pts)", chordDrag),
                               ("P1 scroll wheel (not in a corner)", scroll),
                               ("P1 scroll wheel, real front-app lookup", liveScroll)] {
                let s = micros(xs)
                add(name, String(format: "p50 %.1fµs  p99 %.1fµs  max %.0fµs", s.p50, s.p99, s.max), "p99 < 50µs", s.p99 < 50)
            }
        }

        // P2 — release cost vs stroke length and rule count
        do {
            var rng = RNG(state: 1)
            for (label, cfg) in [("default rules", Config.defaultConfig), ("default + 24 glyph rules", fullConfig())] {
                for n in [30, 200, 1000] {
                    let e = engine(cfg)
                    _ = stroke(e, render("S", size: 250, aspect: 1, rotateDeg: 0, jitter: 1, step: 8,
                                         origin: center, rng: &rng), fired: fired)    // warm-up (one-time init)
                    var ts: [UInt64] = []
                    for _ in 0..<40 {
                        let step = max(1, 400.0 / Double(n))
                        let pts = render("S", size: 250, aspect: 1, rotateDeg: 0, jitter: 1, step: step,
                                         origin: center, rng: &rng)
                        ts.append(stroke(e, pts, fired: fired).1)
                    }
                    let s = micros(ts)
                    add("P2 release, \(label), ~\(n) pts", String(format: "p50 %.2fms  max %.2fms", s.p50 / 1000, s.max / 1000),
                        "max < 8ms", s.max < 8000)
                }
            }
        }

        // P3 — recognition stability
        do {
            let e = engine(fullConfig())
            var rng = RNG(state: 42)
            let levels: [(String, ClosedRange<Double>, Double, Double, Double)] = [
                // name, size range, max |rotation|, jitter σ, aspect spread
                ("careful", 150...300, 5, 1.0, 0.10),
                ("normal",  100...300, 10, 2.5, 0.20),
                ("sloppy",  80...250, 15, 4.0, 0.30),
            ]
            for (lname, sizes, rot, jit, asp) in levels {
                var hits = 0, total = 0
                var confusions: [String: Int] = [:]
                var perGlyph: [String: (Int, Int)] = [:]
                for (g, _) in glyphIDs {
                    for _ in 0..<40 {
                        let speed = rng.range(3, 25)            // pt between samples: slow … fast mouse
                        let pts = render(g, size: rng.range(sizes.lowerBound, sizes.upperBound),
                                         aspect: 1 + rng.range(-asp, asp), rotateDeg: rng.range(-rot, rot),
                                         jitter: jit, step: speed, origin: center, rng: &rng)
                        let got = stroke(e, pts, fired: fired).0
                        total += 1
                        var pg = perGlyph[g] ?? (0, 0); pg.1 += 1
                        if isHit(g, got) { hits += 1; pg.0 += 1 } else { confusions["\(g)→\(got ?? "∅")", default: 0] += 1 }
                        perGlyph[g] = pg
                    }
                }
                let rate = Double(hits) / Double(total) * 100
                let need: Double = lname == "careful" ? 98 : (lname == "normal" ? 95 : 85)
                let worst = perGlyph.map { ($0.key, Double($0.value.0) / Double($0.value.1) * 100) }
                    .sorted { $0.1 < $1.1 }.prefix(3).map { "\($0.0) \(Int($0.1))%" }.joined(separator: ", ")
                let top = confusions.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                add("P3 hit rate, \(lname) strokes", String(format: "%.1f%%  (worst: %@)", rate, worst),
                    "≥ \(Int(need))%", rate >= need)
                if !top.isEmpty { add("   confusions (\(lname))", top, "info", true) }
            }
            // short / tiny strokes must not fire a *shape* by accident
            var tinyShape = 0
            for _ in 0..<200 {
                // extent stays below the 30 pt gate even with jitter (size ≤ 22 + 3σ)
                let pts = render(["A", "S", "O"][Int(rng.next() % 3)], size: rng.range(10, 22), aspect: 1, rotateDeg: 0,
                                 jitter: 1, step: 3, origin: center, rng: &rng)
                if let g = stroke(e, pts, fired: fired).0, g.count == 1, g.first!.isLetter { tinyShape += 1 }
            }
            add("P3 tiny strokes (< 30pt) fire a letter", "\(tinyShape)/200", "0", tinyShape == 0)
        }

        // P4 — trail cost per event
        do {
            var long: [CGPoint] = []
            for i in 0..<2000 { long.append(CGPoint(x: 400 + Double(i % 600), y: 300 + Double(i / 600) * 40)) }
            let frame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1728, height: 1117)
            var ts: [UInt64] = []
            for n in stride(from: 10, through: 2000, by: 10) {
                let t0 = now()
                _ = GestureTrail.localPoints(Array(long.prefix(n)), screenFrame: frame, mainHeight: frame.maxY)
                ts.append(now() - t0)
            }
            let s = micros(ts)
            add("P4 trail point conversion (≤ 2000 pts)", String(format: "p99 %.1fµs  max %.0fµs", s.p99, s.max),
                "max < 200µs", s.max < 200)
            // offscreen draw of a 2000-point path, as the overlay does each frame
            let path = NSBezierPath()
            path.move(to: long[0]); for p in long.dropFirst() { path.line(to: p) }
            path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width), pixelsHigh: Int(frame.height),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            var draws: [UInt64] = []
            for _ in 0..<20 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let t0 = now(); NSColor.systemTeal.setStroke(); path.stroke(); path.stroke()
                NSGraphicsContext.current?.flushGraphics(); draws.append(now() - t0)
                NSGraphicsContext.restoreGraphicsState()
            }
            let d = micros(draws)
            add("P4 trail draw, 2000-pt path (2 strokes)", String(format: "p50 %.2fms  max %.2fms", d.p50 / 1000, d.max / 1000),
                "p50 < 8ms (120Hz frame)", d.p50 < 8000)
        }

        // P5 — what the gesture path can block on
        do {
            // The tap callback calls Actions.perform; with the production executor the
            // action's work runs on Actions.workQueue. Simulate a 100 ms action and time
            // how long the *caller* (= the tap) is held.
            let a = Actions()
            a.executor = { work in Actions.workQueue.async { usleep(100_000); work() } }
            Actions.dryRun = false
            let savedObserver = Actions.observer
            Actions.observer = nil
            var held: [UInt64] = []
            let spec = ActionSpec(type: "nothing", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil)
            for _ in 0..<20 { let t0 = now(); a.perform(spec); held.append(now() - t0) }
            Actions.workQueue.sync {}                                // drain
            Actions.dryRun = true
            Actions.observer = savedObserver
            let h = micros(held)
            add("P5 tap held while a 100ms action runs", String(format: "max %.0fµs", h.max), "max < 1000µs", h.max < 1000)

            var fa: [UInt64] = []
            for _ in 0..<200 { let t0 = now(); _ = NSWorkspace.shared.frontmostApplication?.bundleIdentifier; fa.append(now() - t0) }
            let f = micros(fa)
            add("P5 NSWorkspace front-app query (now cached)", String(format: "p50 %.0fµs  max %.0fµs", f.p50, f.max),
                "info: was per scroll event", true)

            var vol: [UInt64] = []
            for _ in 0..<50 { let t0 = now(); _ = OutputVolume.current(); vol.append(now() - t0) }
            let v = micros(vol)
            add("P5 CoreAudio volume read (new volume path)", String(format: "p50 %.0fµs  max %.0fµs", v.p50, v.max),
                "info: was AppleScript", true)

            var ts: [UInt64] = []
            for _ in 0..<5 {
                let t0 = now()
                var err: NSDictionary?
                NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&err)
                ts.append(now() - t0)
            }
            let s = micros(ts)
            add("P5 in-process NSAppleScript (old volume path)", String(format: "p50 %.1fms  max %.1fms", s.p50 / 1000, s.max / 1000),
                "info: no longer on the gesture path", true)
            var ax: [UInt64] = []
            if let front = NSWorkspace.shared.frontmostApplication {
                let app = AXUIElementCreateApplication(front.processIdentifier)
                for _ in 0..<20 {
                    var v: CFTypeRef?
                    let t0 = now()
                    _ = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v)
                    ax.append(now() - t0)
                }
                let a = micros(ax)
                add("P5 AX focused-window read (window actions)", String(format: "p50 %.2fms  max %.2fms", a.p50 / 1000, a.max / 1000),
                    "info: off the tap, capped at \(Actions.axTimeout)s", true)
            }
        }

        // Report
        let w = results.map(\.name.count).max() ?? 30
        print("GestureKit --perf (ordinary-mouse gesture smoothness)\n")
        for r in results {
            let pad = String(repeating: " ", count: max(0, w - r.name.count))
            let mark = r.budget.hasPrefix("info") ? "    " : (r.ok ? "PASS" : "FAIL")
            print("\(mark)  \(r.name)\(pad)  \(r.value)   [\(r.budget)]")
        }
        let failed = results.filter { !$0.ok }.count
        print(failed == 0 ? "\nALL BUDGETS MET" : "\n\(failed) BUDGET(S) MISSED")
        return failed == 0 ? 0 : 1
    }
}
