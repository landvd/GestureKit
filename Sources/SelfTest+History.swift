import Cocoa

// 识别兜底 / 危险动作门槛 / 日志分离 / 动作名称 / 未识别提示 / 手势记录与自动学习
extension SelfTest {
    static func historyChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        func act(_ name: String, _ type: String = "system") -> ActionSpec {
            var a = ActionSpec(type: type, keyCode: nil, modifiers: nil, label: name, op: "missionControl", delta: nil)
            a.note = name; return a
        }
        func cfg(_ ids: [String: ActionSpec]) -> Config {
            var c = Config.defaultConfig
            c.rulesets = ["default": Ruleset(gestures: ids)]
            c.learnedStrokes = nil; c.rejectedStrokes = nil
            return c
        }
        /// Polyline sampled every 6 pt (what a mouse reports), CG coordinates.
        func stroke(_ poly: [CGPoint]) -> [CGPoint] {
            var pts = [poly[0]]
            for k in 1..<poly.count {
                let a = poly[k - 1], b = poly[k]
                let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 6))
                for j in 1...n { pts.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(j) / CGFloat(n),
                                                    y: a.y + (b.y - a.y) * CGFloat(j) / CGFloat(n))) }
            }
            return pts
        }
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 600 + x, y: 500 + y) }
        func rec(_ c: Config, _ pts: [CGPoint]) -> Recognition {
            Recognizer.recognize(points: pts, rules: c.rulesets["default"]!, config: c)
        }

        // ① 方向兜底只给直线
        do {
            let c = cfg(["twoKey.left": act("后退"), "twoKey.right": act("前进")])
            // A loop that ends a bit left of where it started: no shape matches; used to fire 后退.
            let loop = stroke([P(0, 0), P(80, -60), P(140, 20), P(60, 90), P(-50, 10)])
            check("fallback: a scribble ending to the left does not fire 后退", rec(c, loop).via == .none, "\(rec(c, loop).via)")
            let line = stroke([P(0, 0), P(-200, 8)])
            let r = rec(c, line)
            check("fallback: a straight stroke left still fires 后退", r.fires && r.spec?.note == "后退", "\(r.via)")
            check("fallback: straightness test", Recognizer.isStraight(line, minLength: 40)
                  && !Recognizer.isStraight(loop, minLength: 40)
                  && !Recognizer.isStraight(stroke([P(0, 0), P(10, 0)]), minLength: 40))
        }

        // ② 危险动作要更有把握
        do {
            let cmdQ = ActionSpec(type: "shortcut", keyCode: 12, modifiers: 0x00100000, label: "⌘Q", op: nil, delta: nil)
            var c = cfg(["twoKey.key.<": cmdQ])
            c.shapeThreshold = 40                                   // let a so-so stroke pass the normal bar
            let soso = stroke([P(0, 0), P(-100, 20), P(-30, 130)])  // a lopsided "<" (scores ~81)
            let r = rec(c, soso)
            check("danger: a so-so match does not run ⌘Q", r.via == .unsure && !r.fires,
                  "\(r.via) \(Int(r.score))")
            var safe = c; safe.rulesets["default"] = Ruleset(gestures: ["twoKey.key.<": act("窗口最小化")])
            check("danger: the same stroke runs a harmless action", rec(safe, soso).fires)
            let clean = cfg(["twoKey.key.<": cmdQ])
            check("danger: a clean < still runs ⌘Q", rec(clean, stroke([P(0, 0), P(-100, 50), P(0, 100)])).fires)
            check("danger: which actions are dangerous",
                  Recognizer.isDangerous(cmdQ)
                  && Recognizer.isDangerous(ActionSpec(type: "quitApp", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil))
                  && Recognizer.isDangerous(ActionSpec(type: "shortcut", keyCode: 13, modifiers: 0x00100000, label: nil, op: nil, delta: nil))
                  && !Recognizer.isDangerous(ActionSpec(type: "shortcut", keyCode: 15, modifiers: 0x00100000, label: nil, op: nil, delta: nil)))
        }

        // ③ 自检日志不进用户日志
        check("log: self-test writes to a temporary file, not the user's log",
              Log.isTestRun && Log.url.path.hasPrefix(NSTemporaryDirectory()) && Log.url.lastPathComponent == "gesturekit-test.log")
        check("log: rolls over to gesturekit.1.log", Log.previousURL.lastPathComponent == "gesturekit-test.1.log" && Log.maxBytes == 2_000_000)

        // ④ 动作一栏显示用途
        do {
            func sc(_ k: Int, _ m: UInt32) -> ActionSpec { ActionSpec(type: "shortcut", keyCode: k, modifiers: m, label: nil, op: nil, delta: nil) }
            let saved = L10n.override; L10n.override = "zh"
            check("names: ⌘R / ⌘[ / ⌃⌘F say what they do",
                  ActionCatalog.title(for: sc(15, 0x00100000)) == "刷新" && ActionCatalog.title(for: sc(33, 0x00100000)) == "后退"
                  && ActionCatalog.title(for: sc(3, 0x00140000)) == "切换全屏")
            check("names: unknown shortcuts stay 快捷键", ActionCatalog.title(for: sc(1, 0x00100000)) == "快捷键")
            check("names: HUD says 刷新 for an un-noted ⌘R", ActionCatalog.hudText(for: sc(15, 0x00100000)) == "刷新")
            L10n.override = saved
        }

        // ⑤ 未识别 / 未执行时的提示
        do {
            func r(_ via: Recognition.Via) -> GestureRecord {
                GestureRecord(time: Date(), app: "", points: [], gestureID: nil, score: 0, via: via, action: "退出当前 App")
            }
            check("hint: shown for 未识别 / 把握不足 / 已忽略, not for gestures that ran",
                  AppDelegate.hint(for: r(.none)) == L("未识别") && AppDelegate.hint(for: r(.unsure)) != nil
                  && AppDelegate.hint(for: r(.rejected)) != nil && AppDelegate.hint(for: r(.shape)) == nil)
        }

        // 记录：引擎上报每一次手势
        do {
            let e = GestureEngine(config: cfg(["twoKey.right": act("前进"), "twoKey.key.a": act("全部最小化", "window")]))
            e.rulesetOverride = "selftest.none"
            e.isButtonHeld = { _ in true }
            var got: [(Recognition, Int)] = []
            e.onRecognized = { r, pts, _ in got.append((r, pts.count)) }
            func ev(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton) -> CGEvent {
                CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
            }
            _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, P(0, 0), .left))
            _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, P(0, 0), .right))
            for x in stride(from: 10, through: 200, by: 10) {
                _ = e.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, P(CGFloat(x), 0), .left))
            }
            _ = e.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!)
            _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, P(200, 0), .right))
            _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, P(200, 0), .left))
            check("history: chord + letter key is reported as a key gesture",
                  got.count == 1 && got.first?.0.via == .key && got.first?.0.gestureID == "twoKey.key.a", "\(got.map { $0.0.via })")
            got = []
            _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, P(0, 0), .left))
            _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, P(0, 0), .right))
            for x in stride(from: 10, through: 200, by: 10) {
                _ = e.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, P(CGFloat(x), 0), .left))
            }
            _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, P(200, 0), .right))
            _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, P(200, 0), .left))
            check("history: a stroke is reported with its points", got.count == 1 && got[0].0.fires && got[0].1 > 10)
        }

        // 存储：上限、压缩、编解码
        do {
            let h = GestureHistory(file: nil)
            for i in 0..<(GestureHistory.capacity + 5) {
                h.add(GestureRecord(time: Date(), app: "a", points: [], gestureID: "\(i)", score: 0, via: .none, action: ""))
            }
            check("history: keeps the newest \(GestureHistory.capacity)",
                  h.records.count == GestureHistory.capacity && h.records.first?.gestureID == "\(GestureHistory.capacity + 4)")
            let long = (0..<500).map { CGPoint(x: CGFloat($0) + 100, y: 50) }
            let c = GestureHistory.compact(long)
            check("history: stroke stored relative and ≤ 64 points (+ last)",
                  c.count <= 65 && c.first == .zero && c.last == CGPoint(x: 499, y: 0), "\(c.count) \(String(describing: c.last))")
            var r = h.records[0]; r.rating = .bad; r.intended = "twoKey.up"; r.comment = "测试"
            let back = try? JSONDecoder().decode(GestureRecord.self, from: JSONEncoder().encode(r))
            check("history: record round-trips through JSON", back == r)
            let model = PrefModel(config: .defaultConfig)
            model.history = h
            model.rateGood(h.records[1])
            check("history: 👍 marks a record good", h.records[1].rating == .good)
            model.rateGood(h.records[1])
            check("history: 👍 again clears it", h.records[1].rating == nil)
        }

        // 自动学习：正样本
        do {
            var c = cfg(["twoKey.upThenDown": act("刷新"), "twoKey.left": act("后退")])
            let odd = stroke([P(0, 0), P(60, -120), P(120, 0), P(180, -120)])     // an "N"-ish wiggle
            check("learn: the wiggle is not recognized at first", rec(c, odd).via == .none, "\(rec(c, odd).via)")
            let record = GestureRecord(time: Date(), app: "", points: GestureHistory.compact(odd), gestureID: nil,
                                       score: 0, via: .none, action: "")
            c = GestureHistory.learning(from: record, intended: "twoKey.upThenDown", into: c)
            let similar = stroke([P(0, 0), P(66, -110), P(126, 6), P(176, -128)])
            let r = rec(c, similar)
            check("learn: after 「我想画的是 上下」, a similar wiggle runs 上下", r.fires && r.gestureID == "twoKey.upThenDown",
                  "\(r.via) \(r.gestureID ?? "-") \(Int(r.score))")
            check("learn: the built-in 上下 still works", rec(c, stroke([P(0, 0), P(0, -180), P(0, 0)])).gestureID == "twoKey.upThenDown")
            for k in 0..<8 {                                     // 8 different strokes
                var other = record
                other.points = GestureHistory.compact(stroke([P(0, 0), P(60, -120 - CGFloat(k) * 4), P(120, 0), P(180, -120)]))
                c = GestureHistory.learning(from: other, intended: "twoKey.upThenDown", into: c)
            }
            check("learn: at most \(GestureHistory.maxLearned) strokes per gesture",
                  c.learnedStrokes?["twoKey.upThenDown"]?.count == GestureHistory.maxLearned)
        }

        // 自动学习：反例
        do {
            var c = cfg(["twoKey.key.a": act("全部最小化", "window"), "twoKey.upThenDown": act("刷新")])
            let wideA = stroke([P(0, 0), P(90, -180), P(180, 0)])
            let first = rec(c, wideA)
            check("reject: the stroke first runs A", first.fires && first.gestureID == "twoKey.key.a")
            let record = GestureRecord(time: Date(), app: "", points: GestureHistory.compact(wideA), gestureID: "twoKey.key.a",
                                       score: first.score, via: .shape, action: "全部最小化")
            c = GestureHistory.learning(from: record, intended: GestureHistory.noneIntended, into: c)
            let again = rec(c, stroke([P(0, 0), P(92, -176), P(182, 2)]))
            check("reject: after 「不该触发」 the same kind of stroke no longer runs A",
                  !again.fires && again.via == .rejected, "\(again.via)")
            check("reject: other gestures are unaffected", rec(c, stroke([P(0, 0), P(0, -180), P(0, 0)])).fires)
            let taught = GestureHistory.learning(from: record, intended: "twoKey.key.a", into: c)
            check("reject: teaching it back as A removes the counter-example",
                  taught.rejectedStrokes?["twoKey.key.a"]?.isEmpty == true)
            let keyOnly = GestureRecord(time: Date(), app: "", points: [], gestureID: "twoKey.key.a", score: 100, via: .key, action: "")
            check("reject: a key gesture has nothing to learn",
                  GestureHistory.learnedCount(GestureHistory.learning(from: keyOnly, intended: GestureHistory.noneIntended, into: c))
                    == GestureHistory.learnedCount(c))
            let legacy = #"{"version":1,"enabled":true,"minDistance":24,"cornerSize":40,"rulesets":{}}"#
            let old = try? JSONDecoder().decode(Config.self, from: Data(legacy.utf8))
            check("learn: old rules.json loads with no learning data", old != nil && old?.learnedStrokes == nil)
        }

        // 优化（来自真实手势记录）
        do {
            // 同分时结果固定：不随字典顺序变化
            let s1 = stroke([P(0, 0), P(40, -150), P(160, -120), P(200, 20)])
            var tie = cfg(["twoKey.upThenRight": act("关标签"), "twoKey.downThenRight": act("下一标签")])
            tie.learnedStrokes = ["twoKey.upThenRight": [GestureHistory.compact(s1)], "twoKey.downThenRight": [GestureHistory.compact(s1)]]
            let picks = Set((0..<30).map { _ in rec(tie, s1).gestureID ?? "-" })
            check("tune: equal scores always pick the same gesture", picks.count == 1, "\(picks)")

            // 教过的样本：危险动作也直接执行
            let cmdQ = ActionSpec(type: "shortcut", keyCode: 12, modifiers: 0x00100000, label: "⌘Q", op: nil, delta: nil)
            var c = cfg(["twoKey.key.<": cmdQ])
            c.shapeThreshold = 40
            let lopsided = stroke([P(0, 0), P(-100, 20), P(-30, 130)])      // scores ~81
            check("tune: an untaught so-so 「<」 still needs more confidence", rec(c, lopsided).via == .unsure)
            let r = GestureRecord(time: Date(), app: "", points: GestureHistory.compact(lopsided), gestureID: "twoKey.key.<",
                                  score: 80, via: .unsure, action: "退出当前 App", rating: .bad, intended: "twoKey.key.<")
            c = GestureHistory.learning(from: r, intended: "twoKey.key.<", into: c)
            let again = rec(c, stroke([P(0, 0), P(-98, 24), P(-34, 126)]))
            check("tune: once taught, your own 「<」 runs ⌘Q", again.fires, "\(again.via) \(Int(again.score))")
            check("tune: danger threshold is 88", Recognizer.dangerThreshold == 88)

            // 一笔只属于一个手势：改教给 X 时从别的手势里拿掉
            var d = cfg(["twoKey.upThenRight": act("关标签"), "twoKey.downThenRight": act("下一标签")])
            let rr = GestureRecord(time: Date(), app: "", points: GestureHistory.compact(s1), gestureID: nil,
                                   score: 0, via: .none, action: "")
            d = GestureHistory.learning(from: rr, intended: "twoKey.downThenRight", into: d)
            d = GestureHistory.learning(from: rr, intended: "twoKey.upThenRight", into: d)
            check("tune: re-teaching a stroke moves it, not copies it",
                  d.learnedStrokes?["twoKey.upThenRight"]?.count == 1 && d.learnedStrokes?["twoKey.downThenRight"] == nil)

            // 旧数据：同一笔挂在两个手势下 → 以记录里最新的评价为准
            var rated = rr; rated.rating = .bad; rated.intended = "twoKey.upThenRight"
            let fixed = GestureHistory.reconcile(tie, with: [rated])
            check("tune: old duplicate samples follow the latest rating",
                  fixed.learnedStrokes?["twoKey.upThenRight"]?.count == 1 && fixed.learnedStrokes?["twoKey.downThenRight"] == nil)
            check("tune: samples with no rating are kept", GestureHistory.reconcile(tie, with: []).learnedStrokes?.count == 2)
        }
        return out
    }
}
