import Cocoa

// 组合手势的「吞 / 放行」规则：第一个键的按下已到达 App，它的抬起也必须到达；
// 加入组合的键按下被吞，抬起与拖动也吞。任何一条错了，App 会以为某个键一直按着
// （卡顿、取消选择、下一次点击被误判），或弹出右键菜单。
extension SelfTest {
    static func chordChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        func makeEngine() -> GestureEngine {
            let e = GestureEngine(config: .defaultConfig)
            e.rulesetOverride = "selftest.none"
            e.isButtonHeld = { _ in true }
            return e
        }
        func ev(_ type: CGEventType, _ p: CGPoint, _ button: Int64) -> CGEvent {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                            mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)!
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            return e
        }
        let a = CGPoint(x: 600, y: 500), b = CGPoint(x: 760, y: 500)
        let saved = Actions.observer
        defer { Actions.observer = saved }
        var fired: [ActionSpec] = []
        Actions.observer = { fired.append($0) }

        /// Feed events; returns which were passed (true) / swallowed (false).
        func run(_ e: GestureEngine, _ steps: [(CGEventType, CGPoint, Int64)]) -> [Bool] {
            steps.map { e.handle(type: $0.0, event: ev($0.0, $0.1, $0.2)) != nil }
        }

        // 1) 左 → 右，划线，先松右再松左
        do {
            fired = []
            let r = run(makeEngine(), [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1),
                                       (.leftMouseDragged, b, 0), (.rightMouseUp, b, 1), (.leftMouseUp, b, 0)])
            check("chord L→R, release R first: left down/up pass, right down/up + drag swallowed",
                  r == [true, false, false, false, true], "\(r)")
            check("chord L→R fires one action", fired.count == 1, "\(fired.count)")
        }
        // 2) 左 → 右，先松左再松右（以前左键抬起被吞 → App 以为左键一直按着）
        do {
            fired = []
            let r = run(makeEngine(), [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1),
                                       (.leftMouseDragged, b, 0), (.leftMouseUp, b, 0),
                                       (.rightMouseDragged, b, 1), (.rightMouseUp, b, 1)])
            check("chord L→R, release L first: left up passes, right drag/up after chord swallowed",
                  r == [true, false, false, true, false, false], "\(r)")
            check("chord L→R (L first) fires one action", fired.count == 1, "\(fired.count)")
        }
        // 3) 右 → 左（右键先按，按下已放行 → 抬起也放行，左键全吞）
        do {
            let r = run(makeEngine(), [(.rightMouseDown, a, 1), (.leftMouseDown, a, 0),
                                       (.rightMouseDragged, b, 1), (.leftMouseUp, b, 0), (.rightMouseUp, b, 1)])
            check("chord R→L: right down/up pass, left down/up swallowed",
                  r == [true, false, false, false, true], "\(r)")
        }
        // 4) 拖选文字中途按侧键：侧键吞，左键抬起放行（选择不被取消）
        do {
            let e = makeEngine()
            let r = run(e, [(.leftMouseDown, a, 0), (.leftMouseDragged, b, 0), (.otherMouseDown, b, 3),
                            (.otherMouseUp, b, 3), (.leftMouseDragged, a, 0), (.leftMouseUp, a, 0)])
            check("drag-select + side button: side swallowed, left drag/up after chord pass",
                  r == [true, true, false, false, true, true], "\(r)")
        }
        // 5) 单独中键 / 侧键：全部放行
        do {
            let r = run(makeEngine(), [(.otherMouseDown, a, 2), (.otherMouseUp, a, 2),
                                       (.otherMouseDown, a, 3), (.otherMouseUp, a, 3),
                                       (.otherMouseDown, a, 4), (.otherMouseUp, a, 4)])
            check("lone middle / side clicks pass untouched", r.allSatisfy { $0 }, "\(r)")
        }
        // 6) 组合结束后，普通右键单击照常（不残留状态）
        do {
            let e = makeEngine()
            _ = run(e, [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1), (.leftMouseDragged, b, 0),
                        (.leftMouseUp, b, 0), (.rightMouseUp, b, 1)])
            let r = run(e, [(.rightMouseDown, a, 1), (.rightMouseUp, a, 1),
                            (.leftMouseDown, a, 0), (.leftMouseUp, a, 0)])
            check("after a chord, plain right/left clicks pass", r.allSatisfy { $0 }, "\(r)")
        }
        // 7) 识别延后执行：回调返回时动作还没跑，排队的工作跑完才触发
        do {
            fired = []
            let e = makeEngine()
            var queued: [() -> Void] = []
            e.deferWork = { queued.append($0) }
            let r = run(e, [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1),
                            (.leftMouseDragged, b, 0), (.rightMouseUp, b, 1), (.leftMouseUp, b, 0)])
            check("deferred recognition: swallow decision doesn't wait for it",
                  r == [true, false, false, false, true] && fired.isEmpty && queued.count == 1)
            queued.forEach { $0() }
            check("deferred recognition: action fires when the queued work runs", fired.count == 1)
        }

        // 8) 右键手势模式（gestureButton = "right"）
        do {
            var cfg = Config.defaultConfig
            cfg.gestureButton = "right"
            func rightEngine() -> GestureEngine {
                let e = makeEngine(); e.config = cfg; return e
            }
            let savedPost = GestureEngine.postRightClick
            defer { GestureEngine.postRightClick = savedPost }
            var replayed: [CGPoint] = []
            GestureEngine.postRightClick = { replayed.append($0) }

            // 按住右键向右划 → 手势；右键按下/拖动/抬起全吞，不补发右键
            fired = []; replayed = []
            var r = run(rightEngine(), [(.rightMouseDown, a, 1), (.rightMouseDragged, b, 1), (.rightMouseUp, b, 1)])
            check("right mode: right-drag → gesture, all right events swallowed",
                  r == [false, false, false] && fired.count == 1 && replayed.isEmpty, "\(r) fired=\(fired.count)")
            check("right mode: right-drag → twoKey.right rule (⌘[)", fired.first?.keyCode == 33)

            // 单击右键（不动或抖几个像素）→ 不触发动作，在按下的位置补发右键（菜单照常）
            fired = []; replayed = []
            r = run(rightEngine(), [(.rightMouseDown, a, 1), (.rightMouseDragged, CGPoint(x: a.x + 3, y: a.y), 1),
                                    (.rightMouseUp, CGPoint(x: a.x + 3, y: a.y), 1)])
            check("right mode: plain right click is replayed at the press point",
                  r == [false, false, false] && fired.isEmpty && replayed == [a], "\(r) \(replayed)")

            // 按住右键 + 字母键 → 字母规则，不补发右键
            fired = []; replayed = []
            let e = rightEngine()
            _ = run(e, [(.rightMouseDown, a, 1)])
            let key = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!   // A
            let kr = e.handle(type: .keyDown, event: key)
            _ = run(e, [(.rightMouseUp, a, 1)])
            check("right mode: right + A → twoKey.key.a, key swallowed, no replay",
                  kr == nil && fired.first?.op == "minimizeAll" && replayed.isEmpty)

            // 左键在右键模式下完全照常
            r = run(rightEngine(), [(.leftMouseDown, a, 0), (.leftMouseDragged, b, 0), (.leftMouseUp, b, 0)])
            check("right mode: left click/drag untouched", r.allSatisfy { $0 }, "\(r)")

            // 补发的右键带合成标记 → 引擎放行（不会再被当成手势吞掉）
            let syn = ev(.rightMouseDown, a, 1)
            syn.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            check("right mode: replayed (synthetic) right click passes", rightEngine().handle(type: .rightMouseDown, event: syn) != nil)

            // 缺省仍是双键：单独右键照常放行
            r = run(makeEngine(), [(.rightMouseDown, a, 1), (.rightMouseUp, a, 1)])
            check("default mode: lone right click passes", r == [true, true], "\(r)")
        }

        // 9) 真实 tap 回调那一层：引擎说吞（nil）必须保持 nil（以前 `?? pass` 把所有吞都变成了放行）
        do {
            let e = makeEngine()
            let steps: [(CGEventType, CGPoint, Int64)] = [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1),
                                                         (.leftMouseDragged, b, 0), (.rightMouseUp, b, 1), (.leftMouseUp, b, 0)]
            let r = steps.map { EventTap.dispatch(e, type: $0.0, event: ev($0.0, $0.1, $0.2)) != nil }
            check("tap dispatch keeps the engine's swallow (chord right-click never reaches the app)",
                  r == [true, false, false, false, true], "\(r)")
            check("tap dispatch without engine passes", EventTap.dispatch(nil, type: .rightMouseDown, event: ev(.rightMouseDown, a, 1)) != nil)
        }

        // 10) App 专属规则 + 全局规则合并（原版：App 专属 > 全局）
        do {
            let json = #"""
            {"version":1,"enabled":true,"minDistance":24,"cornerSize":40,"gestureButton":"right","rulesets":{
              "default":{"gestures":{"twoKey.key.a":{"type":"window","op":"minimizeAll"},
                                     "twoKey.downRight":{"type":"window","op":"minimize"},
                                     "twoKey.left":{"type":"system","op":"pageBack"},
                                     "twoKey.upLeft":{"type":"window","op":"restore"}}},
              "com.apple.Safari":{"gestures":{"twoKey.left":{"type":"system","op":"closeTab"},
                                              "twoKey.upLeft":{"type":"window","op":"restore","enabled":false}}}}}
            """#
            guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
                check("rules merge: test config decodes", false); return out
            }
            let rs = GestureEngine.effectiveRules(cfg, app: "com.apple.Safari").gestures
            check("rules merge: app inherits global rules it doesn't define",
                  rs["twoKey.key.a"]?.op == "minimizeAll" && rs["twoKey.downRight"]?.op == "minimize")
            check("rules merge: app rule wins over the global one", rs["twoKey.left"]?.op == "closeTab")
            check("rules merge: disabled app rule switches the gesture off in that app", rs["twoKey.upLeft"] == nil)
            check("rules merge: other apps use the global rules",
                  GestureEngine.effectiveRules(cfg, app: "com.other").gestures["twoKey.left"]?.op == "pageBack")

            let e = makeEngine(); e.config = cfg; e.rulesetOverride = "com.apple.Safari"
            let savedPost = GestureEngine.postRightClick
            defer { GestureEngine.postRightClick = savedPost }
            GestureEngine.postRightClick = { _ in }
            fired = []
            _ = run(e, [(.rightMouseDown, a, 1)])
            _ = e.handle(type: .keyDown, event: CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!)
            _ = run(e, [(.rightMouseUp, a, 1)])
            check("Safari: right + A → global minimizeAll", fired.first?.op == "minimizeAll", "\(fired.map(\.op))")
            fired = []
            _ = run(e, [(.rightMouseDown, a, 1), (.rightMouseDragged, CGPoint(x: a.x + 40, y: a.y + 40), 1),
                        (.rightMouseDragged, CGPoint(x: a.x + 90, y: a.y + 90), 1),
                        (.rightMouseUp, CGPoint(x: a.x + 90, y: a.y + 90), 1)])
            check("Safari: right-drag ↘ → global minimize", fired.first?.op == "minimize", "\(fired.map(\.op))")
        }

        // 11) 四个折线手势：上左 ↑← / 上右 ↑→ / 下左 ↓← / 下右 ↓→
        do {
            func act(_ name: String) -> ActionSpec {
                var a = ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: name, op: "missionControl", delta: nil)
                a.note = name; return a
            }
            var cfg = Config.defaultConfig
            var g: [String: ActionSpec] = [:]
            for id in ["upThenLeft", "upThenRight", "downThenLeft", "downThenRight",
                       "upLeft", "upRight", "downLeft", "downRight", "left", "up"] { g["twoKey.\(id)"] = act(id) }
            g["twoKey.key.f"] = act("F"); g["twoKey.key.l"] = act("L")      // same shapes as ↑→ / ↓→
            cfg.rulesets = ["default": Ruleset(gestures: g)]
            /// Draw a polyline with the left+right chord, sampled every 6 pt.
            func draw(_ poly: [CGPoint]) -> String? {
                fired = []
                let e = makeEngine(); e.config = cfg
                var pts = [poly[0]]
                for k in 1..<poly.count {
                    let a = poly[k - 1], b = poly[k]
                    let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 6))
                    for j in 1...n { pts.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(j) / CGFloat(n),
                                                        y: a.y + (b.y - a.y) * CGFloat(j) / CGFloat(n))) }
                }
                _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, pts[0], 0))
                _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, pts[0], 1))
                for p in pts.dropFirst() { _ = e.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, p, 0)) }
                _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, pts.last!, 1))
                _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, pts.last!, 0))
                return fired.first?.note
            }
            // CG coordinates: +y is down
            let o = CGPoint(x: 600, y: 500)
            func P(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: o.x + dx, y: o.y + dy) }
            let cases: [(String, [CGPoint])] = [
                ("upThenLeft",    [P(0, 0), P(0, -150), P(-150, -150)]),
                ("upThenRight",   [P(0, 0), P(0, -150), P(150, -150)]),
                ("downThenLeft",  [P(0, 0), P(0, 150), P(-150, 150)]),
                ("downThenRight", [P(0, 0), P(0, 150), P(150, 150)]),
            ]
            for (want, poly) in cases {
                let got = draw(poly)
                check("polyline: \(want) fires its rule", got == want, "got \(got ?? "nothing")")
            }
            // 长短不一（先长后短 / 先短后长）也要认出来
            check("polyline: uneven legs (long up, short left)", draw([P(0, 0), P(0, -200), P(-90, -200)]) == "upThenLeft")
            check("polyline: uneven legs (short down, long right)", draw([P(0, 0), P(0, 90), P(200, 90)]) == "downThenRight")
            // 斜线与直线不受影响
            check("polyline: diagonal ↖ still the diagonal rule", draw([P(0, 0), P(-150, -150)]) == "upLeft")
            check("polyline: diagonal ↘ still the diagonal rule", draw([P(0, 0), P(150, 150)]) == "downRight")
            check("polyline: straight ↑ still the straight rule", draw([P(0, 0), P(0, -200)]) == "up")
            // 与字母 F / L 同形：每次都判给折线（不随字典顺序变化）
            let ties = (0..<20).map { _ in draw([P(0, 0), P(0, -150), P(150, -150)]) }
            check("polyline: ↑→ beats the same-shaped letter F every time", ties.allSatisfy { $0 == "upThenRight" }, "\(Set(ties.map { $0 ?? "-" }))")
            // 名称 / 编辑器
            let opts = Set(RuleDraft.gestureOptions(for: .normalMouse).map(\.id))
            check("polyline: editor offers the 4 new gestures",
                  opts.isSuperset(of: GlyphLibrary.polylineIDs) && opts.contains("twoKey.upLeft"))
            check("polyline: names",
                  PrefModel.gestureName("twoKey.upThenLeft") == L("按住右键 + ") + L("上左") + " ↑←"
                  && PrefModel.gestureName("twoKey.downThenRight") == L("按住右键 + ") + L("下右") + " ↓→")
        }

        // 12) 线程模型：事件线程独立；引擎把 UI 工作交给 uiQueue；识别用快照、不碰引擎状态
        do {
            var onTapThread = false, isMain = true
            TapThread.shared.sync { onTapThread = Thread.current.name == "gesturekit.tap"; isMain = Thread.isMainThread }
            check("thread: TapThread runs blocks on its own (non-main) thread", onTapThread && !isMain)

            let e = makeEngine()
            var ui: [() -> Void] = []
            e.uiQueue = { ui.append($0) }
            _ = e.handle(type: .mouseMoved, event: ev(.mouseMoved, a, 0))
            check("thread: window-dock work is handed to uiQueue, not run in the tap", ui.count == 1)

            // Recognition runs later on a snapshot: changing the rules meanwhile doesn't change the result.
            fired = []
            var queued: [() -> Void] = []
            e.deferWork = { queued.append($0) }
            _ = run(e, [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1), (.leftMouseDragged, b, 0),
                        (.rightMouseUp, b, 1), (.leftMouseUp, b, 0)])
            var emptied = e.config; emptied.rulesets = [:]
            e.config = emptied
            queued.forEach { $0() }
            check("thread: recognition uses the rules of the moment the stroke ended", fired.count == 1, "\(fired.count)")

            // Trail updates are throttled while drawing; the final one always comes.
            let t = makeEngine()
            t.strokeInterval = 10
            var strokes: [Bool] = []
            t.onChordStroke = { _, done in strokes.append(done) }
            _ = run(t, [(.leftMouseDown, a, 0), (.rightMouseDown, a, 1)])
            for x in stride(from: 610, through: 800, by: 10) {
                _ = t.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, CGPoint(x: CGFloat(x), y: a.y), 0))
            }
            _ = run(t, [(.rightMouseUp, b, 1), (.leftMouseUp, b, 0)])
            check("thread: trail updates throttled while drawing, final one sent",
                  strokes == [false, true], "\(strokes)")
        }

        // 13) 上下 ↑↓（默认刷新）：不与 ↑ / ↓ / 字母 A 混淆
        do {
            func act(_ name: String) -> ActionSpec {
                var a = ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: name, op: "missionControl", delta: nil)
                a.note = name; return a
            }
            var cfg = Config.defaultConfig
            var g: [String: ActionSpec] = [:]
            for id in ["upThenDown", "up", "down", "upLeft", "upRight", "upThenLeft", "upThenRight"] { g["twoKey.\(id)"] = act(id) }
            g["twoKey.key.a"] = act("A"); g["twoKey.key.v"] = act("V")
            cfg.rulesets = ["default": Ruleset(gestures: g)]
            func draw(_ poly: [CGPoint]) -> String? {
                fired = []
                let e = makeEngine(); e.config = cfg
                var pts = [poly[0]]
                for k in 1..<poly.count {
                    let p0 = poly[k - 1], p1 = poly[k]
                    let n = max(1, Int(hypot(p1.x - p0.x, p1.y - p0.y) / 6))
                    for j in 1...n { pts.append(CGPoint(x: p0.x + (p1.x - p0.x) * CGFloat(j) / CGFloat(n),
                                                        y: p0.y + (p1.y - p0.y) * CGFloat(j) / CGFloat(n))) }
                }
                _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, pts[0], 0))
                _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, pts[0], 1))
                for p in pts.dropFirst() { _ = e.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, p, 0)) }
                _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, pts.last!, 1))
                _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, pts.last!, 0))
                return fired.first?.note
            }
            let o = CGPoint(x: 600, y: 500)
            func P(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: o.x + dx, y: o.y + dy) }
            check("up-down: straight up and back", draw([P(0, 0), P(0, -180), P(0, 0)]) == "upThenDown")
            check("up-down: hand drift (top 10 pt to the side, back 15 pt off)",
                  draw([P(0, 0), P(10, -170), P(15, -10)]) == "upThenDown")
            check("up-down: comes back only part way", draw([P(0, 0), P(0, -200), P(4, -90)]) == "upThenDown")
            check("up-down: straight up is still ↑", draw([P(0, 0), P(0, -200)]) == "up")
            check("up-down: straight down is still ↓", draw([P(0, 0), P(0, 200)]) == "down")
            check("up-down: a wide caret is still the letter A", draw([P(0, 0), P(90, -180), P(180, 0)]) == "A")
            let def = Config.defaultConfig.rulesets["default"]?.gestures["twoKey.upThenDown"]
            check("up-down: factory default is refresh ⌘R", def?.type == "shortcut" && def?.keyCode == 15
                  && def?.modifiers == 0x00100000 && def?.note == "刷新")
            check("up-down: editor offers it, named 上下 ↑↓",
                  RuleDraft.gestureOptions(for: .normalMouse).contains { $0.id == "twoKey.upThenDown" }
                  && PrefModel.gestureName("twoKey.upThenDown") == L("按住右键 + ") + L("上下") + " ↑↓")
        }

        // 14) 普通鼠标页「添加应用程序…」：选这一项不会把它当成分组选中
        do {
            let model = PrefModel(config: .defaultConfig)
            var asked = 0
            model.presentAddApp = { asked += 1 }                       // no real panel in selftest
            model.selectedApp = "com.apple.Safari"
            model.appSelection.wrappedValue = PrefModel.addAppTag
            check("apps: 「添加应用程序…」 opens the chooser and keeps the current group selected",
                  asked == 1 && model.selectedApp == "com.apple.Safari")
            model.appSelection.wrappedValue = "default"
            check("apps: picking a group selects it", model.selectedApp == "default")
        }

        // 15) 删除某个应用的专属规则组
        do {
            var cfg = Config.defaultConfig                              // Safari + ego lite groups
            cfg.rulesets["com.citrolabs.ego.lite"]?.gestures["twoKey.custom.9"] = ActionSpec(
                type: "shortcut", keyCode: 15, modifiers: 0x00100000, label: "⌘R", op: nil, delta: nil)
            cfg.customGlyphs = ["9": [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)]]
            let r = PrefModel.removingApp("com.citrolabs.ego.lite", from: cfg)
            check("apps: deleting a group removes only that app",
                  r.rulesets["com.citrolabs.ego.lite"] == nil && r.rulesets["com.apple.Safari"] != nil
                  && r.rulesets["default"]?.gestures.count == cfg.rulesets["default"]?.gestures.count)
            check("apps: drawn shapes only that app used are dropped too", r.customGlyphs?["9"] == nil)
            check("apps: 所有应用程序 can't be deleted",
                  PrefModel.removingApp("default", from: cfg).rulesets["default"] != nil)
            check("apps: deleted app falls back to the global rules",
                  GestureEngine.effectiveRules(r, app: "com.citrolabs.ego.lite").gestures["twoKey.key.t"] == nil
                  && GestureEngine.effectiveRules(r, app: "com.citrolabs.ego.lite").gestures["twoKey.key.a"]?.op == "minimizeAll")
            // 取消确认：什么都不改（不写盘）
            let model = PrefModel(config: cfg)
            model.confirmRemoveApp = { _ in false }
            model.selectedApp = "com.citrolabs.ego.lite"
            model.removeApp("com.citrolabs.ego.lite")
            check("apps: cancelling the delete changes nothing",
                  model.config.rulesets["com.citrolabs.ego.lite"] != nil && model.selectedApp == "com.citrolabs.ego.lite")
        }
        return out
    }
}
