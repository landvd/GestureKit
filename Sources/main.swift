import Cocoa

// MARK: - Self test

enum SelfTest {

    static func run() -> Int32 {
        L10n.override = "zh"          // 现有断言比对中文文案：任何系统语言下都按中文跑
        Actions.dryRun = true
        var fired: [ActionSpec] = []
        Actions.observer = { fired.append($0) }

        var failures = 0
        func expect(_ name: String, _ body: () -> Void, _ check: (ActionSpec?) -> Bool) {
            fired.removeAll()
            body()
            let hit = fired.first
            let ok = check(hit)
            print("\(ok ? "PASS" : "FAIL")  \(name)" + (ok ? "" : "  (got: \(hit.map { "\($0.type)/\($0.op ?? $0.label ?? "")" } ?? "nil"))"))
            if !ok { failures += 1 }
        }

        func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton) -> CGEvent {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
        }
        func makeEngine(_ config: Config = .defaultConfig) -> GestureEngine {
            let e = GestureEngine(config: config)
            e.rulesetOverride = "selftest.none"
            e.isButtonHeld = { _ in true }        // test events don't touch the real button state
            return e
        }
        func chord(_ from: CGPoint, _ to: CGPoint) {
            let engine = makeEngine()
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, from, button: .left))
            _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, from, button: .right))
            _ = engine.handle(type: .leftMouseDragged, event: mouse(.leftMouseDragged, to, button: .left))
            _ = engine.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, to, button: .left))
            _ = engine.handle(type: .rightMouseUp, event: mouse(.rightMouseUp, to, button: .right))
        }

        let origin = CGPoint(x: 600, y: 500)

        expect("twoKey.right → ⌘[", { chord(origin, CGPoint(x: 700, y: 500)) }) {
            $0?.type == "shortcut" && $0?.keyCode == 33
        }
        expect("twoKey.left → ⌘]", { chord(origin, CGPoint(x: 500, y: 500)) }) {
            $0?.type == "shortcut" && $0?.keyCode == 30
        }
        expect("twoKey.downRight → minimize", { chord(origin, CGPoint(x: 680, y: 580)) }) {
            $0?.type == "window" && $0?.op == "minimize"
        }
        expect("twoKey.upLeft → restore", { chord(origin, CGPoint(x: 520, y: 420)) }) {
            $0?.type == "window" && $0?.op == "restore"
        }
        expect("twoKey.downLeft → ⌃⌘F", { chord(origin, CGPoint(x: 520, y: 580)) }) {
            $0?.type == "shortcut" && $0?.keyCode == 3
        }
        expect("twoKey+key a → minimizeAll", {
            let engine = makeEngine()
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, origin, button: .right))
            let k = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            _ = engine.handle(type: .keyDown, event: k)
        }) { $0?.type == "window" && $0?.op == "minimizeAll" }

        expect("twoKey+key v → restoreAll", {
            let engine = makeEngine()
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, origin, button: .right))
            let k = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
            _ = engine.handle(type: .keyDown, event: k)
        }) { $0?.type == "window" && $0?.op == "restoreAll" }

        expect("twoKey+shift+, → quitApp", {
            let engine = makeEngine()
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, origin, button: .right))
            let k = CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: true)!
            k.flags = .maskShift
            _ = engine.handle(type: .keyDown, event: k)
        }) { $0?.type == "quitApp" }

        // Hot corner: scroll down in the top-right corner of the main screen.
        let screen = NSScreen.screens.first!
        let corner = CGPoint(x: screen.frame.maxX - 10, y: 10)   // CG coords, top-right
        expect("corner topRight scroll → volume", {
            let engine = makeEngine()
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                 wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
            scroll.location = corner
            _ = engine.handle(type: .scrollWheel, event: scroll)
        }) { $0?.type == "volume" }

        expect("corner burst fires once", {
            let engine = makeEngine()
            for _ in 0..<20 {
                let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                     wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
                scroll.location = corner
                _ = engine.handle(type: .scrollWheel, event: scroll)
            }
        }) { _ in fired.count == 1 }

        func draw(cfg: Config = .defaultConfig, _ pts: [CGPoint]) {
            let engine = makeEngine(cfg)
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, pts[0], button: .left))
            _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, pts[0], button: .right))
            for p in pts.dropFirst() {
                _ = engine.handle(type: .leftMouseDragged, event: mouse(.leftMouseDragged, p, button: .left))
            }
            if let last = pts.last {
                _ = engine.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, last, button: .left))
            }
        }

        // 三键组合（左+右+中）应同样识别为组合手势
        expect("3-button chord ← → ⌘]", {
            let engine = makeEngine()
            let p0 = CGPoint(x: 700, y: 500)
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, p0, button: .left))
            _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, p0, button: .right))
            let mid = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                              mouseCursorPosition: p0, mouseButton: .center)!
            _ = engine.handle(type: .otherMouseDown, event: mid)
            for x in stride(from: 680, through: 560, by: -10) {
                let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                mouseCursorPosition: CGPoint(x: x, y: 500), mouseButton: .left)!
                _ = engine.handle(type: .leftMouseDragged, event: d)
            }
            _ = engine.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, CGPoint(x: 560, y: 500), button: .left))
        }) { $0?.type == "shortcut" && $0?.keyCode == 30 }

        expect("shape ← → ⌘]", { draw([CGPoint(x: 600, y: 400), CGPoint(x: 480, y: 400)]) }) {
            $0?.type == "shortcut" && $0?.keyCode == 30
        }
        expect("shape → → ⌘[", { draw([CGPoint(x: 600, y: 400), CGPoint(x: 720, y: 400)]) }) {
            $0?.type == "shortcut" && $0?.keyCode == 33
        }
        expect("shape A → minimizeAll", {
            draw([CGPoint(x: 600, y: 500), CGPoint(x: 660, y: 380), CGPoint(x: 720, y: 500)])
        }) { $0?.type == "window" && $0?.op == "minimizeAll" }
        expect("shape V → restoreAll", {
            draw([CGPoint(x: 600, y: 380), CGPoint(x: 660, y: 500), CGPoint(x: 720, y: 380)])
        }) { $0?.type == "window" && $0?.op == "restoreAll" }

        // 窗口布局几何（Cocoa 坐标，y 向上）
        let vf = CGRect(x: 0, y: 25, width: 1000, height: 700)
        func checkLayout(_ name: String, _ op: WindowLayout.Op, _ want: CGRect) -> Bool {
            let got = WindowLayout.frame(for: op, in: vf)
            let ok = got == want
            print("\(ok ? "PASS" : "FAIL")  \(name)  got=\(got) want=\(want)")
            return ok
        }
        var layoutOK = true
        layoutOK = checkLayout("halfLeft", .halfLeft, CGRect(x: 0, y: 25, width: 500, height: 700)) && layoutOK
        layoutOK = checkLayout("halfRight", .halfRight, CGRect(x: 500, y: 25, width: 500, height: 700)) && layoutOK
        layoutOK = checkLayout("halfTop", .halfTop, CGRect(x: 0, y: 375, width: 1000, height: 350)) && layoutOK
        layoutOK = checkLayout("halfBottom", .halfBottom, CGRect(x: 0, y: 25, width: 1000, height: 350)) && layoutOK
        layoutOK = checkLayout("quarterTopRight", .quarterTopRight, CGRect(x: 500, y: 375, width: 500, height: 350)) && layoutOK
        layoutOK = checkLayout("maximize", .maximize, vf) && layoutOK

        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 700),
                       CGRect(x: 1000, y: 0, width: 1600, height: 900)]
        if let moved = WindowLayout.movedToAdjacentScreen(
            currentFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            screens: screens, size: CGSize(width: 400, height: 300), forward: true) {
            let ok = moved == CGRect(x: 1600, y: 300, width: 400, height: 300)
            print("\(ok ? "PASS" : "FAIL")  nextScreen got=\(moved)")
            if !ok { layoutOK = false }
        } else {
            print("FAIL  nextScreen returned nil"); layoutOK = false
        }
        if !layoutOK { failures += 1 }

        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)" + (ok || detail.isEmpty ? "" : "  (\(detail))"))
            if !ok { failures += 1 }
        }

        // MARK: HUD
        func spec(_ type: String, op: String? = nil, label: String? = nil, note: String? = nil) -> ActionSpec {
            var s = ActionSpec(type: type, keyCode: nil, modifiers: nil, label: label, op: op, delta: nil)
            s.note = note
            return s
        }
        check("hud: note wins", ActionCatalog.hudText(for: spec("window", op: "minimize", note: "收起")) == "收起")
        check("hud: spaces-only note = silent", ActionCatalog.hudText(for: spec("window", op: "minimize", note: "  ")) == nil)
        check("hud: action name", ActionCatalog.hudText(for: spec("window", op: "minimize")) == "窗口最小化")
        check("hud: shortcut label", ActionCatalog.hudText(for: spec("shortcut", label: "⌘]")) == "⌘]")
        do {
            let vis = NSRect(x: 0, y: 0, width: 1000, height: 800)
            let size = NSSize(width: 100, height: 30)
            let mid = HUD.origin(for: size, cursor: NSPoint(x: 500, y: 400), in: vis)
            let corner = HUD.origin(for: size, cursor: NSPoint(x: 990, y: 10), in: vis)
            check("hud: below-right of cursor", mid == NSPoint(x: 516, y: 354), "\(mid)")
            check("hud: flips at screen edge", corner == NSPoint(x: 874, y: 26), "\(corner)")
        }

        // MARK: Scroll wheel (smooth scrolling removed: never swallowed or re-posted)
        do {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
            e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 30)
            e.location = CGPoint(x: 600, y: 500)                 // not in a hot corner
            check("scroll: plain wheel notch passes untouched", makeEngine().handle(type: .scrollWheel, event: e) != nil)
        }

        // MARK: Rule editor
        do {
            let model = PrefModel(config: .defaultConfig)
            model.page = .normalMouse
            model.selectedApp = "default"
            var d = RuleDraft.new(model: model)
            d.app = "com.selftest.app"
            d.gestureID = "twoKey.key.m"
            d.actionID = "snap/maximize"
            d.note = "最大化"
            let c1 = d.apply(to: model.config)
            let added = c1?.rulesets["com.selftest.app"]?.gestures["twoKey.key.m"]
            check("editor: new rule creates app ruleset", added?.type == "snap" && added?.op == "maximize"
                  && added?.note == "最大化")

            model.config = c1!
            model.selectedApp = "com.selftest.app"
            var e = RuleDraft.edit(model: model, id: "twoKey.key.m")!
            check("editor: edit loads existing rule", e.actionID == "snap/maximize" && e.note == "最大化")
            e.gestureID = "twoKey.key.n"
            let c2 = e.apply(to: model.config)!
            check("editor: edit moves rule", c2.rulesets["com.selftest.app"]?.gestures["twoKey.key.m"] == nil
                  && c2.rulesets["com.selftest.app"]?.gestures["twoKey.key.n"]?.op == "maximize")

            var sc = RuleDraft.new(model: model)
            sc.app = "default"
            sc.gestureID = "twoKey.key.k"
            sc.actionID = RuleDraft.shortcutChoice
            sc.shortcut = .init(code: 17, flags: 0x00100000)            // ⌘T
            let sr = sc.apply(to: .defaultConfig)?.rulesets["default"]?.gestures["twoKey.key.k"]
            check("editor: gesture + shortcut action rule", sr?.type == "shortcut" && sr?.keyCode == 17
                  && sr?.modifiers == 0x00100000 && sr?.label == "⌘T", "\(String(describing: sr))")
            check("editor: removed pages are gone",
                  !PrefPage.allCases.map(\.zhTitle).contains { ["触控板", "妙控鼠标", "键盘", "脚本库", "学习教程", "免费 Apps", "问题反馈"].contains($0) })
            var incomplete = RuleDraft.new(model: model)
            incomplete.actionID = RuleDraft.shortcutChoice
            check("editor: incomplete draft not saved", incomplete.apply(to: .defaultConfig) == nil)
        }

        // MARK: Custom drawn gestures
        do {
            // A "⊐⊏" zig-zag none of the built-in glyphs look like.
            let shape = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50),
                         CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)]
            var cfg = Config.defaultConfig
            cfg.customGlyphs = ["1": shape]
            cfg.rulesets["default"]!.gestures["twoKey.custom.1"] = spec("system", op: "lockScreen", label: "custom")
            expect("custom glyph: same shape, other size/place fires", {
                let engine = makeEngine(cfg)
                let drawn = shape.map { CGPoint(x: 400 + $0.x * 1.6, y: 300 + $0.y * 1.4) }
                var pts: [CGPoint] = []
                for i in 1..<drawn.count {
                    let a = drawn[i - 1], b = drawn[i]
                    for k in 0..<6 {
                        let t = CGFloat(k) / 6
                        pts.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    }
                }
                pts.append(drawn[drawn.count - 1])
                _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, pts[0], button: .left))
                _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, pts[0], button: .right))
                for p in pts.dropFirst() {
                    _ = engine.handle(type: .leftMouseDragged, event: mouse(.leftMouseDragged, p, button: .left))
                }
                _ = engine.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, pts.last!, button: .left))
            }) { $0?.label == "custom" }
            expect("custom glyph: straight line still hits →", {
                let engine = makeEngine(cfg)
                _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, CGPoint(x: 600, y: 400), button: .left))
                _ = engine.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, CGPoint(x: 600, y: 400), button: .right))
                _ = engine.handle(type: .leftMouseDragged, event: mouse(.leftMouseDragged, CGPoint(x: 720, y: 400), button: .left))
                _ = engine.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, CGPoint(x: 720, y: 400), button: .left))
            }) { $0?.label != "custom" && $0?.keyCode == 33 }

            let model = PrefModel(config: .defaultConfig)
            model.page = .normalMouse
            var d = RuleDraft.new(model: model)
            d.gestureID = RuleDraft.customChoice
            d.actionID = "system/lockScreen"
            d.customStroke = [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5)]
            check("custom draft: tiny stroke rejected", d.apply(to: model.config) == nil)
            d.customStroke = shape
            let c = d.apply(to: model.config)
            check("custom draft: stores glyph + rule", c?.customGlyphs?["1"]?.count == shape.count
                  && c?.rulesets["default"]?.gestures["twoKey.custom.1"]?.op == "lockScreen")
            var pruned = c!
            pruned.rulesets["default"]!.gestures["twoKey.custom.1"] = nil
            pruned.pruneCustomGlyphs()
            check("custom draft: orphan glyph pruned", pruned.customGlyphs?["1"] == nil)
            model.config = c!
            let e = RuleDraft.edit(model: model, id: "twoKey.custom.1")
            check("custom draft: edit keeps name + stroke", e?.gestureID == RuleDraft.customChoice
                  && e?.customName == "1" && e?.customStroke.count == shape.count)
        }

        // MARK: Import / export
        do {
            var mine = Config.defaultConfig
            mine.blacklist = ["com.a"]
            var theirs = Config(version: 1, enabled: true, minDistance: 24, cornerSize: 40, shapeThreshold: 85,
                                blacklist: ["com.b"], rulesets: [:])
            theirs.rulesets["com.apple.Safari"] = Ruleset(gestures: [
                "twoKey.key.t": spec("system", op: "newTab", label: "imported"),
                "twoKey.key.z": spec("system", op: "closeTab", label: "new")])
            let merged = ConfigIO.combine(current: mine, imported: theirs, mode: .merge)
            let safari = merged.rulesets["com.apple.Safari"]?.gestures
            check("import merge: same id overridden", safari?["twoKey.key.t"]?.label == "imported")
            check("import merge: new id added, others kept", safari?["twoKey.key.z"] != nil
                  && safari?["twoKey.key.r"] != nil && merged.rulesets["default"] != nil)
            check("import merge: blacklist union", merged.blacklist == ["com.a", "com.b"])
            let replaced = ConfigIO.combine(current: mine, imported: theirs, mode: .replace)
            check("import replace: takes file as-is", replaced.rulesets["default"] == nil && replaced.blacklist == ["com.b"])

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("gk-selftest-\(getpid())", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("rules.json")
            var roundTrip: Config?
            if (try? ConfigIO.export(mine, to: file)) != nil, let data = try? Data(contentsOf: file) {
                roundTrip = try? ConfigIO.decode(data)
            }
            check("export → import round trip", roundTrip?.rulesets.keys.sorted() == mine.rulesets.keys.sorted()
                  && roundTrip?.blacklist == ["com.a"])
            check("import: garbage rejected", (try? ConfigIO.decode(Data("not json".utf8))) == nil)
            let copy = ConfigIO.backup(file)
            check("backup: copy written next to file", copy.map { FileManager.default.fileExists(atPath: $0.path) } == true
                  && copy?.lastPathComponent.hasPrefix("rules.backup-") == true)
        }

        // MARK: Brightness / DDC
        do {
            typealias DDC = DisplayBrightness.DDC
            check("ddc: get-brightness packet", DDC.readPacket(vcp: 0x10) == [0x82, 0x01, 0x10, 0xAC])
            check("ddc: set-brightness packet", DDC.writePacket(vcp: 0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
            let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
            let parsed = DDC.parseReply(reply, vcp: 0x10)
            check("ddc: parse reply", parsed?.current == 50 && parsed?.max == 100)
            check("ddc: error reply rejected", DDC.parseReply([0x6E, 0x88, 0x02, 0x01, 0x10, 0, 0, 0x64, 0, 0x32, 0], vcp: 0x10) == nil
                  && DDC.parseReply([0, 0, 0], vcp: 0x10) == nil)
            check("brightness: step 1/16 of 100", DisplayBrightness.step(current: 50, max: 100, delta: 0.0625) == 56
                  && DisplayBrightness.step(current: 3, max: 100, delta: -0.0625) == 0)
            check("brightness: tiny range still moves", DisplayBrightness.step(current: 5, max: 10, delta: 0.0625) == 6)
            let builtin = DisplayBrightness.DisplayRef(id: 1, builtin: true, frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
            let ext = DisplayBrightness.DisplayRef(id: 2, builtin: false, frame: CGRect(x: 1000, y: 0, width: 1600, height: 900))
            let all = [builtin, ext]
            check("brightness: cursor picks its screen",
                  DisplayBrightness.select(all, cursor: CGPoint(x: 1500, y: 100), target: nil) == [ext]
                  && DisplayBrightness.select(all, cursor: CGPoint(x: 10, y: 10), target: nil) == [builtin])
            check("brightness: external / builtin targets",
                  DisplayBrightness.select(all, cursor: .zero, target: "external") == [ext]
                  && DisplayBrightness.select(all, cursor: .zero, target: "builtin") == [builtin]
                  && DisplayBrightness.select([builtin], cursor: .zero, target: "external").isEmpty)
            var ex = ActionSpec(type: "brightness", keyCode: nil, modifiers: nil, label: nil, op: "external", delta: -0.0625)
            check("brightness: names", ActionCatalog.title(for: ex) == "调低外接屏亮度")
            ex.delta = 0.0625
            check("brightness: editor choice ids distinct", ActionCatalog.choices.filter { $0.spec.type == "brightness" }
                  .map(\.id).count == Set(ActionCatalog.choices.map(\.id).filter { $0.hasPrefix("brightness/") }).count
                  && ActionCatalog.choices.contains { $0.id == ActionCatalog.choiceID(for: ex) })
        }

        // MARK: Presets (P1-7)
        do {
            let vis = CGRect(x: 0, y: 25, width: 1001, height: 700)
            let cur = CGRect(x: 50, y: 100, width: 400, height: 300)
            check("preset: center keeps size", WindowLayout.frame(for: .center, in: vis, current: cur)
                  == CGRect(x: 300, y: 225, width: 400, height: 300))
            check("preset: maximize width", WindowLayout.frame(for: .maximizeWidth, in: vis, current: cur)
                  == CGRect(x: 0, y: 100, width: 1001, height: 300))
            check("preset: maximize height", WindowLayout.frame(for: .maximizeHeight, in: vis, current: cur)
                  == CGRect(x: 50, y: 25, width: 400, height: 700))
            check("preset: oversize window clamped", WindowLayout.frame(for: .center, in: vis,
                  current: CGRect(x: 0, y: 0, width: 3000, height: 2000)) == vis)
            let ax = WindowLayout.toAX(cur, mainHeight: 900)
            check("preset: AX ↔ Cocoa round trip", WindowLayout.fromAX(ax, mainHeight: 900) == cur)
            check("preset: smart zoom tolerance", WindowLayout.approximatelyEqual(vis, vis.insetBy(dx: 3, dy: 3))
                  && !WindowLayout.approximatelyEqual(vis, cur))

            var h = AppHistory()
            for pid: pid_t in [10, 20, 30, 20] { h.activated(pid) }
            check("preset: previous app", h.previous(alive: [10, 20, 30]) == 30 && h.previous(alive: [10, 20]) == 10)

            let grouped = ActionCatalog.systemGroups.flatMap { $0.1 }
            check("preset: every system op grouped once", Set(grouped).count == grouped.count
                  && Set(grouped) == Set(ActionCatalog.systemNames.keys),
                  "missing=\(Set(ActionCatalog.systemNames.keys).subtracting(grouped)) extra=\(Set(grouped).subtracting(ActionCatalog.systemNames.keys))")
            let ids = ActionCatalog.choices.map(\.id)
            check("preset: editor choice ids unique", Set(ids).count == ids.count)
            check("preset: preset count", ActionCatalog.choices.count >= 110, "\(ActionCatalog.choices.count)")

            // Our own events must pass straight through the engine.
            let engine = makeEngine()
            _ = engine.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            let synth = mouse(.rightMouseDown, origin, button: .right)
            synth.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            check("synthetic click does not start a chord", engine.handle(type: .rightMouseDown, event: synth) != nil
                  && engine.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, origin, button: .left)) != nil)
            // Keyboard triggers were removed: a key press outside a mouse chord is never taken.
            var kb = Config.defaultConfig
            kb.rulesets["default"]?.gestures["keyboard.123.524288"] = spec("snap", op: "halfLeft", label: "⌥←")
            let k = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
            k.flags = .maskAlternate
            expect("⌥← without a mouse chord passes (no keyboard rules)", {
                check("⌥← key event passes through", makeEngine(kb).handle(type: .keyDown, event: k) != nil)
            }) { $0 == nil }
        }

        // MARK: Window dock (P1-8)
        do {
            final class FakeWin { var frame: CGRect; init(_ f: CGRect) { frame = f } }
            final class FakeDriver: DockDriver {
                var screens: [CGRect]
                var wins: [FakeWin] = []
                var focused: FakeWin?
                var activated = 0
                var clampX: CGFloat?           // simulate an app that refuses to leave the screen
                init(_ screens: [CGRect]) { self.screens = screens }
                func window(at p: CGPoint) -> AnyObject? { wins.last { $0.frame.contains(p) } }
                func focusedWindow() -> AnyObject? { focused }
                func frame(of w: AnyObject) -> CGRect? { (w as? FakeWin)?.frame }
                func setFrame(_ w: AnyObject, _ r: CGRect) {
                    var r = r
                    if let c = clampX { r.origin.x = max(r.origin.x, c) }
                    (w as? FakeWin)?.frame = r
                }
                func activate(_ w: AnyObject) { activated += 1 }
                func same(_ a: AnyObject, _ b: AnyObject) -> Bool { a === b }
            }
            let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let side = CGRect(x: 1000, y: 0, width: 1600, height: 900)

            check("dock: geometry keeps 1px", WindowDock.hiddenFrame(CGRect(x: 100, y: 100, width: 400, height: 300),
                  side: .left, screen: main).minX == -399
                  && WindowDock.hiddenFrame(CGRect(x: 100, y: 100, width: 400, height: 300), side: .right, screen: main).minX == 999
                  && WindowDock.shownFrame(CGRect(x: 999, y: 100, width: 400, height: 300), side: .right, screen: main).minX == 600)
            check("dock: shared edge between screens ignored",
                  WindowDock.edge(at: CGPoint(x: 999, y: 400), screens: [main, side]) == nil
                  && WindowDock.edge(at: CGPoint(x: 0, y: 400), screens: [main, side])?.side == .left
                  && WindowDock.edge(at: CGPoint(x: 2599, y: 400), screens: [main, side])?.side == .right)

            let drv = FakeDriver([main])
            let dock = WindowDock(driver: drv)
            dock.runAsync = false
            let w = FakeWin(CGRect(x: 300, y: 200, width: 400, height: 300))
            drv.wins = [w]; drv.focused = w
            dock.dockFocused(.left)
            check("dock: action parks window at left", w.frame.minX == -399 && dock.docked.count == 1)
            dock.mouseMoved(to: CGPoint(x: 0, y: 700))
            check("dock: edge outside window height ignored", w.frame.minX == -399)
            dock.mouseMoved(to: CGPoint(x: 0, y: 350))
            check("dock: touching the edge reveals + activates", w.frame.minX == 0 && drv.activated == 1)
            dock.mouseMoved(to: CGPoint(x: 200, y: 350))
            check("dock: stays while cursor on window", w.frame.minX == 0)
            dock.mouseMoved(to: CGPoint(x: 800, y: 350))
            check("dock: leaving re-hides", w.frame.minX == -399)

            // Drag the revealed window away → undocked.
            dock.mouseMoved(to: CGPoint(x: 0, y: 350))
            dock.mouseDown(at: CGPoint(x: 100, y: 450))
            w.frame.origin = CGPoint(x: 300, y: 250)
            dock.mouseUp(at: CGPoint(x: 400, y: 500))
            check("dock: dragging away undocks", dock.docked.isEmpty && w.frame.minX == 300)

            // Auto mode: drag a window onto the right edge.
            dock.autoDock = true
            dock.mouseDown(at: CGPoint(x: 400, y: 450))
            w.frame.origin = CGPoint(x: 700, y: 250)
            dock.mouseUp(at: CGPoint(x: 999, y: 450))
            check("dock: auto-dock on drag to edge", w.frame.minX == 999 && dock.docked.first?.side == .right)
            dock.revealAll()
            check("dock: revealAll brings windows back", w.frame.minX == 600 && dock.docked.isEmpty)

            dock.autoDock = false
            dock.mouseDown(at: CGPoint(x: 700, y: 450))
            w.frame.origin = CGPoint(x: 400, y: 250)
            dock.mouseUp(at: CGPoint(x: 0, y: 450))
            check("dock: auto-dock off by default path", dock.docked.isEmpty && w.frame.minX == 400)

            let small = FakeWin(CGRect(x: 100, y: 100, width: 40, height: 40))
            drv.focused = small
            dock.dockFocused(.left)
            check("dock: tiny windows ignored", dock.docked.isEmpty && small.frame.minX == 100)
            drv.focused = w
            drv.clampX = 0
            dock.dockFocused(.left)
            check("dock: app that refuses off-screen is not tracked", dock.docked.isEmpty)
            check("dock: default config leaves auto-dock off", makeEngine().dock.autoDock == false)
        }

        // MARK: Config compatibility
        do {
            let old = #"{"version":1,"enabled":true,"minDistance":24,"cornerSize":40,"rulesets":{"default":{"gestures":{"twoKey.left":{"type":"shortcut","keyCode":30,"modifiers":1048576}}}}}"#
            let cfg = try? JSONDecoder().decode(Config.self, from: Data(old.utf8))
            check("config: old rules.json still loads", cfg != nil && cfg?.showHUD == nil)
            // rules.json written before the slim-down still has smoothScroll / cloudSync / ruleMeta / keyboard rules
            let legacy = #"{"version":1,"enabled":true,"minDistance":24,"cornerSize":40,"smoothScroll":{"speed":5},"cloudSync":true,"ruleMeta":{"a":1},"tombstones":{},"rulesets":{"default":{"gestures":{"keyboard.126.524288":{"type":"snap","op":"halfTop"}}}}}"#
            check("config: rules.json with removed features still loads",
                  (try? JSONDecoder().decode(Config.self, from: Data(legacy.utf8))) != nil)
            var mixed = Config.defaultConfig
            mixed.rulesets["default"]?.gestures["keyboard.126.524288"] = spec("snap", op: "halfTop", label: "⌥↑")
            mixed.rulesets["default"]?.gestures["magicMouse.3f.click"] = spec("system", op: "middleClick", label: "m")
            mixed.rulesets["default"]?.gestures["trackpad.3f.swipeUp"] = spec("system", op: "missionControl", label: "t")
            mixed.rulesets["com.x"] = Ruleset(gestures: ["twoKey.key.z": ActionSpec(type: "script", keyCode: nil, modifiers: nil,
                                                                                      label: nil, op: nil, delta: nil)])
            let (slim, removed) = mixed.withoutRemovedFeatures()
            check("config: migration drops trackpad / keyboard / magic mouse / script rules only",
                  removed == 4 && slim.rulesets["default"]?.gestures["trackpad.3f.swipeUp"] == nil && slim.rulesets["default"]?.gestures["keyboard.126.524288"] == nil
                  && slim.rulesets["default"]?.gestures["magicMouse.3f.click"] == nil
                  && slim.rulesets["com.x"]?.gestures.isEmpty == true
                  && slim.rulesets["default"]?.gestures.count == Config.defaultConfig.rulesets["default"]?.gestures.count)
            check("config: factory rules need no migration", Config.defaultConfig.withoutRemovedFeatures().1 == 0)
        }

        // MARK: Stale button guard
        do {
            let e = makeEngine()
            var held: Set<Int64> = []
            e.isButtonHeld = { held.contains($0) }
            _ = e.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            // left's up was lost (tap disabled); later the user right-clicks normally
            let r = e.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, origin, button: .right))
            check("stale held button doesn't turn a click into a chord", r != nil)
            _ = e.handle(type: .rightMouseUp, event: mouse(.rightMouseUp, origin, button: .right))
            held = [0]
            _ = e.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            let chord = e.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, origin, button: .right))
            check("really held button still starts a chord", chord == nil)
        }

        // MARK: Gesture trail + general settings
        do {
            let local = GestureTrail.localPoints([CGPoint(x: 1100, y: 100)],
                                                 screenFrame: CGRect(x: 1000, y: 0, width: 1600, height: 900), mainHeight: 800)
            check("trail: CG point → view coords on its screen", local == [CGPoint(x: 100, y: 700)], "\(local)")
            let tb = GestureTrail.bounds([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 50)], mainHeight: 1000, margin: 5)
            check("trail: stroke bounds in Cocoa coords", tb == CGRect(x: 95, y: 895, width: 210, height: 60), "\(tb)")
            let g1 = GestureTrail.grown(.null, toFit: tb)
            check("trail: panel covers the stroke, not the whole screen",
                  g1.contains(tb) && g1.width < 600 && g1.height < 600, "\(g1)")
            let tb2 = CGRect(x: 95, y: 895, width: 215, height: 60)        // stroke grew a little
            check("trail: small growth keeps the panel frame", g1.contains(tb2) && GestureTrail.grown(g1, toFit: tb2).contains(g1))
            check("trail: hex colour round trip", GestureTrail.hex(GestureTrail.color(hex: "#87D9FF")!) == "#87D9FF"
                  && GestureTrail.color(hex: "nope") == nil && GestureTrail.color(hex: "12345") == nil)
            let partial = try? JSONDecoder().decode(TrailConfig.self, from: Data(#"{"width":6}"#.utf8))
            check("trail: partial config keeps defaults", partial?.width == 6 && partial?.enabled == true
                  && partial?.color == "#87D9FF")
            let e = makeEngine()
            var calls: [(Int, Bool)] = []
            e.onChordStroke = { pts, done in calls.append((pts.count, done)) }
            _ = e.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            _ = e.handle(type: .rightMouseDown, event: mouse(.rightMouseDown, origin, button: .right))
            for x in stride(from: 610, through: 700, by: 30) {
                _ = e.handle(type: .leftMouseDragged, event: mouse(.leftMouseDragged, CGPoint(x: CGFloat(x), y: 500), button: .left))
            }
            _ = e.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, CGPoint(x: 700, y: 500), button: .left))
            check("trail: engine streams the stroke then signals the end",
                  calls.count == 5 && calls.dropLast().allSatisfy { !$0.1 } && calls.last?.1 == true
                  && calls.map(\.0) == [2, 3, 4, 5, 5], "\(calls)")
            var noChord: [(Int, Bool)] = []
            let e2 = makeEngine()
            e2.onChordStroke = { pts, done in noChord.append((pts.count, done)) }
            _ = e2.handle(type: .leftMouseDown, event: mouse(.leftMouseDown, origin, button: .left))
            _ = e2.handle(type: .leftMouseDragged, event: mouse(.leftMouseDragged, CGPoint(x: 700, y: 500), button: .left))
            _ = e2.handle(type: .leftMouseUp, event: mouse(.leftMouseUp, CGPoint(x: 700, y: 500), button: .left))
            check("trail: plain drag draws nothing", noChord.isEmpty)
            let old = #"{"version":1,"enabled":true,"minDistance":24,"cornerSize":40,"rulesets":{}}"#
            let cfg = try? JSONDecoder().decode(Config.self, from: Data(old.utf8))
            check("config: no trail / menu-icon keys → defaults", cfg != nil && cfg?.trail == nil && cfg?.showMenuBarIcon == nil)
        }

        // MARK: Page reset + new-rule default
        do {
            var cfg = Config.defaultConfig
            cfg.rulesets["default"]!.gestures["twoKey.key.z"] = spec("system", op: "lockScreen")
            cfg.rulesets["default"]!.gestures["twoKey.left"] = spec("system", op: "sleep")
            cfg.rulesets["default"]!.gestures["trackpad.3f.tap"] = spec("system", op: "missionControl")
            let r = PrefModel.resetRules(cfg, page: .normalMouse, app: "default")
            let g = r.rulesets["default"]!.gestures
            let factory = Config.defaultConfig.rulesets["default"]!.gestures.filter { $0.key.hasPrefix("twoKey.") }
            check("reset: page rules back to factory", g["twoKey.key.z"] == nil && g["twoKey.left"]?.keyCode == 30
                  && g.keys.filter { $0.hasPrefix("twoKey.") }.count == factory.count)
            check("reset: other pages untouched", g["trackpad.3f.tap"]?.op == "missionControl" && g["corner.topRight.up"] != nil)
            let other = PrefModel.resetRules(cfg, page: .normalMouse, app: "com.example.none")
            check("reset: app without factory rules is emptied for that page",
                  other.rulesets["com.example.none"]?.gestures.isEmpty == true)
            let model = PrefModel(config: .defaultConfig)
            model.page = .normalMouse
            model.selectedApp = "default"
            let d = RuleDraft.new(model: model)
            check("editor: new rule defaults to a gesture without a rule",
                  Config.defaultConfig.rulesets["default"]!.gestures[d.gestureID] == nil && !d.gestureID.isEmpty, d.gestureID)
        }

        // MARK: Corner scroll reversal
        do {
            fired.removeAll()
            let e = makeEngine()
            func burst(_ d: Int32) {
                for _ in 0..<6 {
                    let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                     wheel1: d, wheel2: 0, wheel3: 0)!
                    ev.location = corner
                    _ = e.handle(type: .scrollWheel, event: ev)
                }
            }
            burst(-10)
            usleep(450_000)                 // past the 0.4 s throttle
            burst(10)
            let deltas = fired.map { $0.delta ?? 0 }
            check("corner: quick reverse scroll fires the opposite action", deltas == [-6, 6], "\(deltas)")
            fired.removeAll()
            let e2 = makeEngine()
            for _ in 0..<3 {
                let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
                ev.location = corner; _ = e2.handle(type: .scrollWheel, event: ev)
            }
            usleep(450_000)
            let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)!
            ev.location = corner; _ = e2.handle(type: .scrollWheel, event: ev)
            check("corner: holding the same direction repeats after the throttle",
                  fired.map { $0.delta ?? 0 } == [-6, -6], "\(fired.map { $0.delta ?? 0 })")
        }

        // MARK: Per-area suites (Sources/SelfTest+*.swift)
        for (_, suite) in SelfTest.suites {
            for c in suite() { check(c.name, c.ok, c.detail) }
        }

        print(failures == 0 ? "\nALL TESTS PASSED" : "\n\(failures) TEST(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--shape-debug") {
    let drawnA = [CGPoint(x: 600, y: 500), CGPoint(x: 640, y: 380), CGPoint(x: 680, y: 500)]
    let drawnV = [CGPoint(x: 600, y: 380), CGPoint(x: 640, y: 500), CGPoint(x: 680, y: 380)]
    let drawnL = [CGPoint(x: 600, y: 400), CGPoint(x: 480, y: 400)]
    let sloppyA = [CGPoint(x: 600, y: 505), CGPoint(x: 625, y: 440), CGPoint(x: 655, y: 385),
                   CGPoint(x: 690, y: 448), CGPoint(x: 715, y: 498)]
    let narrowA = [CGPoint(x: 600, y: 500), CGPoint(x: 640, y: 380), CGPoint(x: 680, y: 500)]
    for (name, d) in [("A", drawnA), ("V", drawnV), ("←", drawnL),
                      ("sloppyA", sloppyA), ("narrowA", narrowA)] {
        print("stroke \(name):")
        for g in ["A", "V", "T", "F", "<", ">", "←", "→", "↑", "↓"] {
            let t = GlyphLibrary.template(for: g)!
            print("   \(g) = \(String(format: "%.1f", ShapeMatcher.score(template: t, drawn: d)))")
        }
    }
    exit(0)
}

if CommandLine.arguments.contains("--ddc-probe") {
    // Read-only: list external displays, DDC services and how they map (no I²C traffic).
    DisplayBrightness.DDC.probeReport().forEach { print($0) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--preset-check"), i + 1 < CommandLine.arguments.count {
    // Read-only: what a .BABPreset would import, and how it differs from the current rules.
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    do {
        let r = try BABImport.parse(try Data(contentsOf: url))
        print(BABImport.summary(r, maxLines: 50))
        let cur = Config.loadOrCreate()
        func text(_ s: ActionSpec?) -> String {
            guard let s else { return "（无）" }
            return (ActionCatalog.hudText(for: s) ?? s.type) + (s.enabled == false ? "［停用］" : "")
        }
        var same = 0, diff: [String] = []
        for app in r.rulesets.keys.sorted() {
            for id in (r.rulesets[app]?.gestures.keys.sorted() ?? []) {
                let mine = cur.rulesets[app]?.gestures[id], theirs = r.rulesets[app]?.gestures[id]
                if text(mine) == text(theirs) { same += 1 } else {
                    diff.append("• [\(app)] \(id)：预设=\(text(theirs))  当前=\(text(mine))")
                }
            }
        }
        print("与当前规则相同 \(same) 条，不同或缺少 \(diff.count) 条")
        diff.forEach { print($0) }
    } catch {
        print("读取失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--ddc-test") {
    // Queries brightness only (DDC "get VCP"); never writes a value.
    DisplayBrightness.DDC.testReport().forEach { print($0) }
    exit(0)
}

if CommandLine.arguments.contains("--perf") {
    exit(PerfBench.run())
}

if CommandLine.arguments.contains("--selftest") {
    let code = SelfTest.run()
    Log.flush()
    exit(code)
}

if CommandLine.arguments.contains("--dry-run") {
    Actions.dryRun = true
    Log.write("dry-run mode: actions will be logged, not executed")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
