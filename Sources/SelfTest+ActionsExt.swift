import Cocoa

// 新动作类型（openApp / openURL / typeText / runShortcut / window moveTo*Space）的自检。
// 全部经 RecordingActionEffects 跑真实 Actions.perform：绝不真的开 App/URL、输入文字、
// 运行快捷指令或合成鼠标拖动。不要在 main.swift 里加这部分断言。
extension SelfTest {
    static func actionExtChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }

        let savedDryRun = Actions.dryRun, savedObserver = Actions.observer, savedPresenter = Actions.presenter
        Actions.dryRun = false
        Actions.observer = nil
        Actions.presenter = nil
        defer {
            Actions.dryRun = savedDryRun
            Actions.observer = savedObserver
            Actions.presenter = savedPresenter
        }

        func spec(_ type: String, _ fill: (inout ActionSpec) -> Void = { _ in }) -> ActionSpec {
            var s = ActionSpec(type: type, keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil)
            fill(&s)
            return s
        }
        func run(_ s: ActionSpec, setup: (RecordingActionEffects) -> Void = { _ in }) -> RecordingActionEffects {
            let fx = RecordingActionEffects()
            setup(fx)
            let actions = Actions()
            actions.effects = fx
            actions.perform(s)
            return fx
        }
        func opened(_ fx: RecordingActionEffects) -> [URL] {
            fx.calls.compactMap { if case .openApplication(let u) = $0 { return u }; return nil }
        }
        func openedURLs(_ fx: RecordingActionEffects) -> [URL] {
            fx.calls.compactMap { if case .open(let u) = $0 { return u }; return nil }
        }
        func tagged(_ e: CGEvent) -> Bool { e.getIntegerValueField(.eventSourceUserData) == Actions.syntheticMarker }
        func unicode(_ e: CGEvent) -> String {
            var len = 0
            var buf = [UniChar](repeating: 0, count: 64)
            e.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &len, unicodeString: &buf)
            return String(utf16CodeUnits: buf, count: len)
        }

        // MARK: openApp
        do {
            let safari = URL(fileURLWithPath: "/Applications/Safari.app")
            let a = run(spec("openApp") { $0.bundleID = "com.apple.Safari"; $0.path = "/old/Safari.app" }) {
                $0.installedApps = ["com.apple.Safari": safari]
            }
            check("actionsExt: openApp opens the app LaunchServices finds for the bundle id",
                  opened(a) == [safari] && a.calls.count == 1)

            let b = run(spec("openApp") { $0.bundleID = "com.example.gone"; $0.path = "/Apps/Foo.app" }) {
                $0.existingPaths = ["/Apps/Foo.app"]
            }
            check("actionsExt: openApp falls back to the saved .app path",
                  opened(b) == [URL(fileURLWithPath: "/Apps/Foo.app")])

            let c = run(spec("openApp") { $0.bundleID = "com.example.gone"; $0.path = "/Apps/Missing.app" })
            check("actionsExt: openApp with nothing found does nothing and logs",
                  c.calls.isEmpty && c.logs.contains { $0.hasPrefix("openApp: app not found") } && c.unknownLogs.isEmpty)

            let d = run(spec("openApp"))
            check("actionsExt: openApp without parameters is safe", d.calls.isEmpty && d.unknownLogs.isEmpty)
        }

        // MARK: openURL
        do {
            let w = run(spec("openURL") { $0.url = " https://www.apple.com/mac " })
            check("actionsExt: openURL opens an https URL (trimmed)",
                  openedURLs(w).map(\.absoluteString) == ["https://www.apple.com/mac"] && w.calls.count == 1)

            let bare = run(spec("openURL") { $0.url = "example.com/a" })
            check("actionsExt: openURL bare host gets https://",
                  openedURLs(bare).map(\.absoluteString) == ["https://example.com/a"])

            let dl = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
            let f = run(spec("openURL") { $0.url = "~/Downloads" }) { $0.existingPaths = [dl] }
            check("actionsExt: openURL ~/path opens the expanded file URL",
                  openedURLs(f).count == 1 && openedURLs(f)[0].isFileURL && openedURLs(f)[0].path == dl)

            let missing = run(spec("openURL") { $0.url = "/no/such/file" })
            check("actionsExt: openURL missing path does nothing and logs",
                  missing.calls.isEmpty && missing.logs.contains("openURL: path not found"))

            let empty = run(spec("openURL") { $0.url = "   " })
            let none = run(spec("openURL"))
            check("actionsExt: openURL empty/nil is safe",
                  empty.calls.isEmpty && none.calls.isEmpty && empty.unknownLogs.isEmpty && none.unknownLogs.isEmpty)

            let r = Actions.resolveURL
            check("actionsExt: resolveURL keeps schemes and host:port",
                  r("mailto:a@b.com")?.absoluteString == "mailto:a@b.com"
                      && r("tel:10086")?.absoluteString == "tel:10086"
                      && r("x-apple.systempreferences:com.apple.preference.security")?.scheme == "x-apple.systempreferences"
                      && r("localhost:3000")?.absoluteString == "https://localhost:3000"
                      && r("example.com:8080/x")?.absoluteString == "https://example.com:8080/x"
                      && r("hello world") == nil && r("") == nil && r(nil) == nil)
        }

        // MARK: typeText
        do {
            let text = "Hi, 你好😀\nok"
            let fx = run(spec("typeText") { $0.text = text; $0.label = "输入文字 Hi, 你好😀" })
            let ev = fx.events
            let uni = ev.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 0 }
            let ret = ev.filter { $0.getIntegerValueField(.keyboardEventKeycode) == 36 }
            let typed = uni.filter { $0.type == .keyDown }.map(unicode).joined()
            check("actionsExt: typeText sends the text as unicode key events + Return for the newline",
                  typed == "Hi, 你好😀ok" && ret.count == 2 && ret[0].type == .keyDown && ret[1].type == .keyUp,
                  "typed=\(typed.count) chars, returns=\(ret.count)")
            check("actionsExt: typeText events are all tagged, unicode ones carry no modifiers",
                  !ev.isEmpty && ev.allSatisfy(tagged) && uni.allSatisfy { $0.flags.rawValue & 0x00FF_0000 == 0 })
            check("actionsExt: typeText order is chunk, Return, chunk",
                  ev.count == 6 && unicode(ev[0]) == "Hi, 你好😀" && ev[2].getIntegerValueField(.keyboardEventKeycode) == 36
                      && unicode(ev[4]) == "ok")
            check("actionsExt: typeText logs only the length, never the text",
                  !fx.logs.contains { $0.contains("你好") || $0.contains("ok") && $0.contains("Hi") }
                      && fx.logs.contains("typeText: \(text.count) chars")
                      && fx.logs.first?.contains("label=<\(text.count) chars>") == true,
                  fx.logs.joined(separator: " / "))

            let long = String(repeating: "abcde", count: 9)                     // 45 units → 20 + 20 + 5
            let lfx = run(spec("typeText") { $0.text = long })
            let downs = lfx.events.filter { $0.type == .keyDown }.map(unicode)
            check("actionsExt: typeText splits into ≤\(Actions.typeChunk)-unit chunks",
                  downs.map(\.count) == [20, 20, 5] && downs.joined() == long && lfx.events.count == 6)

            let emoji = String(repeating: "😀", count: 11)                     // 22 units: never split a pair
            let efx = run(spec("typeText") { $0.text = emoji })
            let eDowns = efx.events.filter { $0.type == .keyDown }.map(unicode)
            check("actionsExt: typeText never splits a surrogate pair",
                  eDowns.map { $0.utf16.count } == [20, 2] && eDowns.joined() == emoji)

            let empty = run(spec("typeText") { $0.text = "" })
            let none = run(spec("typeText"))
            check("actionsExt: typeText empty/nil posts nothing", empty.events.isEmpty && none.events.isEmpty
                  && empty.unknownLogs.isEmpty)
        }

        // MARK: runShortcut
        do {
            let fx = run(spec("runShortcut") { $0.shortcutName = " 专注 开关 " })
            let ok = fx.calls.count == 1 && { if case .run(let p, let a, let w) = fx.calls[0] {
                return p == "/usr/bin/shortcuts" && a == ["run", "专注 开关"] && !w }; return false }()
            check("actionsExt: runShortcut launches `shortcuts run <name>` without waiting", ok)
            let empty = run(spec("runShortcut") { $0.shortcutName = "  " })
            let none = run(spec("runShortcut"))
            check("actionsExt: runShortcut without a name runs nothing",
                  empty.calls.isEmpty && none.calls.isEmpty && none.logs.contains("runShortcut skipped: no name"))
        }

        // MARK: window moveToNextSpace / moveToPrevSpace (experimental)
        do {
            let noWin = run(spec("window") { $0.op = "moveToNextSpace" })
            check("actionsExt: moveToNextSpace without a front window posts nothing",
                  noWin.events.isEmpty && noWin.unknownLogs.isEmpty
                      && noWin.logs.contains { $0.hasPrefix("space move skipped") })

            let winEl = AXUIElementCreateApplication(999_991), btnEl = AXUIElementCreateApplication(999_992)
            func axPoint(_ x: CGFloat, _ y: CGFloat) -> CFTypeRef { var p = CGPoint(x: x, y: y); return AXValueCreate(.cgPoint, &p)! }
            func axSize(_ w: CGFloat, _ h: CGFloat) -> CFTypeRef { var s = CGSize(width: w, height: h); return AXValueCreate(.cgSize, &s)! }
            func fakeWindow(buttonX: CGFloat) -> (RecordingActionEffects) -> Void {
                { fx in
                    fx.frontApp = NSRunningApplication.current
                    fx.cursor = CGPoint(x: 5, y: 7)
                    fx.axHook = { el, attr in
                        if attr == kAXFocusedWindowAttribute as String { return winEl }
                        if CFEqual(el, winEl) {
                            switch attr {
                            case kAXPositionAttribute as String: return axPoint(100, 50)
                            case kAXSizeAttribute as String: return axSize(800, 600)
                            case kAXZoomButtonAttribute as String: return btnEl
                            default: return nil
                            }
                        }
                        if CFEqual(el, btnEl) {
                            switch attr {
                            case kAXPositionAttribute as String: return axPoint(buttonX, 56)
                            case kAXSizeAttribute as String: return axSize(14, 16)
                            default: return nil
                            }
                        }
                        return nil
                    }
                }
            }
            let fx = run(spec("window") { $0.op = "moveToNextSpace" }, setup: fakeWindow(buttonX: 152))
            let ev = fx.events
            let grab = CGPoint(x: 152 + 14 + 8, y: 64)
            let types = ev.map(\.type)
            let key = ev.filter { $0.type == .keyDown || $0.type == .keyUp }
            let delays = fx.calls.compactMap { c -> Double? in if case .after(let s) = c { return s }; return nil }
            check("actionsExt: moveToNextSpace = mouse down on title bar, ⌃→, mouse up, cursor back",
                  types == [.leftMouseDown, .leftMouseDragged, .keyDown, .keyUp, .leftMouseUp, .mouseMoved]
                      && ev[0].location == grab && ev[4].location == grab && ev[5].location == CGPoint(x: 5, y: 7)
                      && key.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 124
                          && $0.flags.rawValue & 0x00FF_0000 == 0x00040000 }
                      && delays == [0.05, 0.35],
                  "\(types.map(\.rawValue)) @\(ev.first?.location ?? .zero)")
            check("actionsExt: moveToNextSpace events are all tagged", !ev.isEmpty && ev.allSatisfy(tagged))

            let prev = run(spec("window") { $0.op = "moveToPrevSpace" }, setup: fakeWindow(buttonX: 152))
            check("actionsExt: moveToPrevSpace sends ⌃←",
                  prev.events.filter { $0.type == .keyDown }.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [123])

            let held = run(spec("window") { $0.op = "moveToNextSpace" }) { fx in
                fakeWindow(buttonX: 152)(fx); fx.buttonHeldFor = 3
            }
            check("actionsExt: moveToNextSpace waits for the gesture's buttons to come up",
                  held.events.map(\.type).first == .leftMouseDown
                      && held.calls.filter { if case .after(0.05) = $0 { return true }; return false }.count == 4)
            let stuck = run(spec("window") { $0.op = "moveToNextSpace" }) { fx in
                fakeWindow(buttonX: 152)(fx); fx.buttonHeldFor = 1000
            }
            check("actionsExt: moveToNextSpace gives up if a button stays held",
                  stuck.events.isEmpty && stuck.logs.contains("space move skipped: mouse button still held"))

            let off = run(spec("window") { $0.op = "moveToNextSpace" }, setup: fakeWindow(buttonX: 2000))
            check("actionsExt: moveToNextSpace skips when the title-bar point is outside the window",
                  off.events.isEmpty && off.logs.contains { $0.hasPrefix("space move skipped") })
        }

        // MARK: names / HUD
        do {
            func title(_ s: ActionSpec) -> String { ActionCatalog.title(for: s) }
            check("actionsExt: title openApp = 打开 Safari",
                  title(spec("openApp") { $0.bundleID = "com.apple.Safari"; $0.path = "/Applications/Safari.app" }) == "打开 Safari")
            check("actionsExt: title openURL web / file",
                  title(spec("openURL") { $0.url = "https://www.apple.com/x" }) == "打开网址 www.apple.com"
                      && title(spec("openURL") { $0.url = "/tmp/a.txt" }) == "打开文件 a.txt"
                      && title(spec("openURL")) == "打开网址或文件")
            check("actionsExt: title typeText shows the clipped first line",
                  title(spec("typeText") { $0.text = "第一行\n第二行" }) == "输入文字 第一行"
                      && title(spec("typeText") { $0.text = String(repeating: "长", count: 30) })
                          == "输入文字 " + String(repeating: "长", count: 16) + "…"
                      && title(spec("typeText")) == "输入文字")
            check("actionsExt: title runShortcut",
                  title(spec("runShortcut") { $0.shortcutName = "勿扰" }) == "运行快捷指令 勿扰"
                      && title(spec("runShortcut")) == "运行快捷指令")
            check("actionsExt: title Space ops are marked experimental",
                  title(spec("window") { $0.op = "moveToNextSpace" }) == "移到下一个桌面（实验）"
                      && title(spec("window") { $0.op = "moveToPrevSpace" }) == "移到上一个桌面（实验）")
            check("actionsExt: hudText uses the title, note still wins",
                  ActionCatalog.hudText(for: spec("runShortcut") { $0.shortcutName = "勿扰" }) == "运行快捷指令 勿扰"
                      && ActionCatalog.hudText(for: spec("typeText") { $0.text = "x"; $0.note = "签名" }) == "签名")
            let ids = Set(ActionCatalog.choices.map(\.id))
            check("actionsExt: catalog offers the experimental Space moves",
                  ids.contains("window/moveToNextSpace") && ids.contains("window/moveToPrevSpace"))
        }

        // MARK: RuleDraft new → save → edit round trips
        do {
            let model = PrefModel(config: .defaultConfig)
            model.page = .normalMouse
            model.selectedApp = "default"
            func roundTrip(_ gid: String, _ fill: (inout RuleDraft) -> Void) -> (ActionSpec?, RuleDraft?) {
                var d = RuleDraft.new(model: model)
                d.gestureID = gid
                fill(&d)
                guard let c = d.apply(to: model.config) else { return (nil, nil) }
                let saved = c.rulesets["default"]?.gestures[gid]
                let m2 = PrefModel(config: c)
                m2.page = .normalMouse
                m2.selectedApp = "default"
                return (saved, RuleDraft.edit(model: m2, id: gid))
            }
            func blank(_ choice: String, _ fill: (inout RuleDraft) -> Void = { _ in }) -> Bool {
                var d = RuleDraft.new(model: model)
                d.gestureID = "twoKey.key.o"
                d.actionID = choice
                fill(&d)
                return d.apply(to: model.config) == nil
            }

            let (a, ae) = roundTrip("twoKey.key.o") {
                $0.actionID = RuleDraft.openAppChoice
                $0.appBundleID = "com.apple.Safari"; $0.appPath = "/Applications/Safari.app"
            }
            check("actionsExt: draft openApp saves bundleID + path and edits back",
                  a?.type == "openApp" && a?.bundleID == "com.apple.Safari" && a?.path == "/Applications/Safari.app"
                      && a?.label == "打开 Safari"
                      && ae?.actionID == RuleDraft.openAppChoice && ae?.appBundleID == "com.apple.Safari"
                      && ae?.appPath == "/Applications/Safari.app")

            let (u, ue) = roundTrip("twoKey.key.u") { $0.actionID = RuleDraft.openURLChoice; $0.urlText = " https://a.b/c " }
            check("actionsExt: draft openURL saves trimmed URL and edits back",
                  u?.type == "openURL" && u?.url == "https://a.b/c"
                      && ue?.actionID == RuleDraft.openURLChoice && ue?.urlText == "https://a.b/c")

            let multi = "第一行\n  第二行 "
            let (t, te) = roundTrip("twoKey.key.i") { $0.actionID = RuleDraft.typeTextChoice; $0.typedText = multi }
            check("actionsExt: draft typeText keeps text verbatim (newlines, spaces) and edits back",
                  t?.type == "typeText" && t?.text == multi && te?.actionID == RuleDraft.typeTextChoice
                      && te?.typedText == multi)

            let (s, se) = roundTrip("twoKey.key.k") { $0.actionID = RuleDraft.runShortcutChoice; $0.shortcutName = " 勿扰 " }
            check("actionsExt: draft runShortcut saves trimmed name and edits back",
                  s?.type == "runShortcut" && s?.shortcutName == "勿扰" && s?.label == "运行快捷指令 勿扰"
                      && se?.actionID == RuleDraft.runShortcutChoice && se?.shortcutName == "勿扰")

            let (sp, spe) = roundTrip("twoKey.key.j") { $0.actionID = "window/moveToNextSpace" }
            check("actionsExt: draft experimental Space move round trips",
                  sp?.type == "window" && sp?.op == "moveToNextSpace" && spe?.actionID == "window/moveToNextSpace")

            check("actionsExt: drafts with empty parameters cannot be saved",
                  blank(RuleDraft.openAppChoice) && blank(RuleDraft.openURLChoice) && blank(RuleDraft.typeTextChoice)
                      && blank(RuleDraft.runShortcutChoice)
                      && blank(RuleDraft.openURLChoice) { $0.urlText = "   " }
                      && blank(RuleDraft.openURLChoice) { $0.urlText = "hello world" }
                      && blank(RuleDraft.runShortcutChoice) { $0.shortcutName = " \n" })

            // Every parameterised editor choice produces a spec perform recognises.
            var specs: [ActionSpec] = []
            for choice in RuleDraft.parameterChoices {
                var d = RuleDraft.new(model: model)
                d.gestureID = "twoKey.key.o"
                d.actionID = choice
                d.shortcut = .init(code: 17, flags: 0x00100000)
                d.appBundleID = "com.example.x"; d.urlText = "https://a.b"
                d.typedText = "x"; d.shortcutName = "x"
                if let sp = d.resolvedSpec { specs.append(sp) }
            }
            let unknown = specs.filter { !run($0).unknownLogs.isEmpty }.map(\.type)
            check("actionsExt: every parameterised editor choice is handled by perform",
                  specs.count == RuleDraft.parameterChoices.count && unknown.isEmpty, unknown.joined(separator: ","))
        }

        // MARK: config compatibility
        do {
            // Old rules.json may still carry removed fields (script/handler/args): ignored, not an error.
            let old = #"{"type":"shortcut","script":"a.scpt","handler":"go","label":"x","note":"n"}"#
            let o = try? JSONDecoder().decode(ActionSpec.self, from: Data(old.utf8))
            check("actionsExt: old ActionSpec JSON still decodes (removed keys ignored, new fields nil)",
                  o?.type == "shortcut" && o?.bundleID == nil && o?.path == nil
                      && o?.url == nil && o?.text == nil && o?.shortcutName == nil)
            let new = #"{"type":"openApp","bundleID":"com.apple.Safari","path":"/Applications/Safari.app","url":"https://a","text":"t\n","shortcutName":"s"}"#
            let n = try? JSONDecoder().decode(ActionSpec.self, from: Data(new.utf8))
            check("actionsExt: new ActionSpec fields decode",
                  n?.bundleID == "com.apple.Safari" && n?.path == "/Applications/Safari.app" && n?.url == "https://a"
                      && n?.text == "t\n" && n?.shortcutName == "s")
            let enc = (try? JSONEncoder.pretty.encode(Config.defaultConfig)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            check("actionsExt: default config encodes without the new keys",
                  !enc.isEmpty && !["bundleID", "shortcutName", "\"text\"", "\"url\"", "\"path\""].contains { enc.contains($0) })
        }

        // MARK: editor helpers
        do {
            check("actionsExt: shortcuts list parsing trims, drops blanks and duplicates",
                  RuleEditorState.parseShortcutsList("勿扰 开\n  专注 \n\n勿扰 开\n") == ["勿扰 开", "专注"]
                      && RuleEditorState.parseShortcutsList("").isEmpty)
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("gk-selftest-apps-\(getpid())")
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dir + "/Zeta.app", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: dir + "/alpha.app", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: dir + "/NotAnApp", withIntermediateDirectories: true)
            let apps = RuleEditorState.scanApps(dirs: [dir, dir + "/missing"], running: [])
            try? fm.removeItem(atPath: dir)
            check("actionsExt: app scan lists .app bundles sorted by name",
                  apps.map(\.name) == ["alpha", "Zeta"] && apps.allSatisfy { $0.path.hasPrefix(dir) })
        }

        return out
    }
}
