import Cocoa

// 原版 .BABPreset 导入与自动备份 的自检。由负责该功能的人填写；不要在 main.swift 里加这部分断言。
// 预设用代码合成（模拟 NSKeyedArchiver 的对象图，内容自拟）；文件操作只在临时目录。
// 绝不读写 ~/Library/Application Support/GestureKit/。
extension SelfTest {

    /// 合成 NSKeyedArchiver 风格的 plist：`$objects` + `$top.root` + `{"CF$UID": n}` 引用。
    private final class FakeArchive {
        struct Point { let x: Double, y: Double }
        var objects: [Any] = ["$null"]
        var classes: [String: [String: Any]] = [:]

        private func add(_ o: Any) -> [String: Any] {
            objects.append(o)
            return ["CF$UID": objects.count - 1]
        }
        private func cls(_ name: String) -> [String: Any] {
            if let c = classes[name] { return c }
            let c = add(["$classname": name, "$classes": [name, "NSObject"]])
            classes[name] = c
            return c
        }
        func encode(_ v: Any) -> [String: Any] {
            switch v {
            case let s as String: return add(s)
            case let p as Point:
                let s = add("{\(p.x), \(p.y)}")
                return add(["NS.pointval": s, "NS.special": 1, "$class": cls("NSValue")])
            case let d as [String: Any]:
                let keys = d.keys.sorted()
                let k = keys.map { encode($0) }
                let o = keys.map { encode(d[$0]!) }
                return add(["NS.keys": k, "NS.objects": o, "$class": cls("NSDictionary")])
            case let a as [Any]:
                return add(["NS.objects": a.map { encode($0) }, "$class": cls("NSArray")])
            default: return add(v)          // NSNumber / Data
            }
        }
        func data(root: Any, binary: Bool = false) -> Data {
            let r = encode(root)
            let plist: [String: Any] = ["$archiver": "NSKeyedArchiver", "$version": 100000,
                                        "$top": ["root": r], "$objects": objects]
            let xml = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            guard binary else { return xml }
            // XML 里的 CF$UID 字典读回来就是真正的 UID 对象；再写成二进制 = 与真实文件相同的形态
            let back = try! PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
            return try! PropertyListSerialization.data(fromPropertyList: back, format: .binary, options: 0)
        }
    }

    private static func rule(_ gesture: Any, _ action: [String: Any], enable: Any = 1, note: String = "",
                             data: Data? = nil) -> [String: Any] {
        var r: [String: Any] = ["Gesture": gesture, "Action": action, "Enable": enable,
                                "Note": note, "Modifier": " -"]
        if let data { r["Data"] = data }
        return r
    }
    private static func preset(_ name: String) -> [String: Any] { ["ActionType": "Preset", "Action": name] }
    private static func keys(_ code: Int, _ flags: Int) -> [String: Any] {
        ["ActionType": "Shortcut Keys", "Action": ["keyCode": code, "modifierFlags": flags, "ShortcutName": "x"]]
    }

    /// 合成的预设（与任何真实用户文件无关）。
    private static func samplePreset(binary: Bool = false) -> Data {
        let stroke = FakeArchive().data(root: [FakeArchive.Point(x: 100, y: 500), FakeArchive.Point(x: 140, y: 440),
                                               FakeArchive.Point(x: 180, y: 500), FakeArchive.Point(x: 220, y: 440)],
                                        binary: true)
        let nsCmdShift = 0x100000 | 0x20000 | 0x108          // 低位是设备相关位，应被丢弃
        let normal: [Any] = [
            ["AppName": "All Applications", "All Rules": [
                rule(" ↑Of2Key", keys(17, nsCmdShift), note: "测试备注"),
                rule("!←Of2Key", preset("Center")),
                rule(" MOf2Key", preset("half_of_Left"), enable: 0),
                rule("!ZOf2Key", preset("VolumeUp"), enable: "1"),
                rule(" BOf2Key", preset("Minimization")),                 // 没有字形 B → 跳过
                rule(" ←Of3Key", preset("Minimization")),                 // 三键 → 跳过
                rule("CustomizeOf2Key", keys(15, 0x100000), data: stroke),
                rule(" ↗Of2Key", ["ActionType": "AppleScript", "Action": "x"]),   // 动作类型不支持
                rule(" ↘Of2Key", preset("Exit"))
            ] as [Any]],
            ["AppName": "com.example.editor", "All Rules": [
                rule("!SOf2Key", preset("Open a New Tab")),
                rule(" ↙Of2Key", preset("NoSuchPreset"))                  // 未知预设 → 跳过
            ] as [Any]],
            ["AppName": "com.example.empty", "All Rules": [] as [Any]]
        ]
        let trackpad: [Any] = [["AppName": "All Applications", "All Rules": [
            rule("2Finger_Swipe_Left", preset("Page Back")),
            rule("3Finger_Swipe_Up_From Bottom", preset("MissionControl")),
            rule("4Finger_Pinch_In", preset("Launchpad")),
            rule("3Finger_TipTap_Left", preset("Launchpad"))               // 不支持 → 跳过
        ] as [Any]]]
        let magic: [Any] = [["AppName": "All Applications", "All Rules": [
            rule("1Finger_Click_Top_Middle", preset("LockScreen")),
            rule("2Finger_Swipe_Down", preset("External Screen BrightnessUp"))
        ] as [Any]]]
        let corners: [Any] = [["AppName": "All Applications", "All Rules": [
            rule("Scroll Down at TopLeft Corner", preset("BrightnessDown")),
            rule("Hover at Somewhere", preset("Mute"))                     // 不支持 → 跳过
        ] as [Any]]]
        let keyboard: [Any] = [["AppName": "All Applications", "All Rules": [
            rule(["keyCode": 40, "modifierFlags": 0xC0000 | 0x20], preset("Mute"), enable: 0),
            rule([String: Any](), ["ActionType": "", "Action": ""], enable: 0)   // 空规则 → 跳过
        ] as [Any]]]
        let root: [String: Any] = [
            "ruleOfNormalMouse": normal, "ruleOfTrackPad": trackpad, "ruleOfMagicMouse": magic,
            "ruleOfHotCorners": corners, "ruleOfKeyboard": keyboard,
            "ruleOfAppleScript": [["Name": "a"], ["Name": "b"]] as [Any],
            "someOtherPreference": 3
        ]
        return FakeArchive().data(root: root, binary: binary)
    }

    static func importChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }

        // MARK: 解析
        let xmlRes = try? BABImport.parse(samplePreset())
        let binRes = try? BABImport.parse(samplePreset(binary: true))
        check("bab: parses synthetic XML archive", xmlRes != nil)
        check("bab: parses binary archive with real UIDs",
              binRes != nil && binRes?.importedCount == xmlRes?.importedCount
              && binRes?.skipped.count == xmlRes?.skipped.count,
              "xml \(xmlRes?.importedCount ?? -1) bin \(binRes?.importedCount ?? -1)")
        guard let r = binRes else { return out }
        let def = r.rulesets["default"]?.gestures ?? [:]

        let up = def["twoKey.up"]
        check("bab: direction gesture + shortcut modifiers (NSEvent → CGEventFlags)",
              up?.type == "shortcut" && up?.keyCode == 17 && up?.modifiers == 0x120000 && up?.label == "⇧⌘T",
              "\(String(describing: up))")
        check("bab: note kept", up?.note == "测试备注" && def["twoKey.right"]?.note == nil)
        check("bab: reversed arrow maps to the opposite direction",
              def["twoKey.right"]?.type == "snap" && def["twoKey.right"]?.op == "center" && def["twoKey.left"] == nil)
        check("bab: letter and reversed letter",
              def["twoKey.key.m"]?.op == "halfLeft" && def["twoKey.key.z"]?.type == "volume"
              && def["twoKey.key.z"]?.delta == 6)
        check("bab: disabled rule kept with enabled=false",
              def["twoKey.key.m"]?.enabled == false && def["twoKey.key.z"]?.enabled == nil
              && up?.enabled == nil)
        check("bab: preset names map to ActionSpec",
              def["twoKey.downRight"]?.type == "quitApp"
              && r.rulesets["com.example.editor"]?.gestures["twoKey.key.s"]?.op == "newTab"
              && BABImport.presetSpec("Minimization Recovery")?.op == "restore"
              && BABImport.presetSpec("Window Enter/Exit Full Screen")?.op == "fullscreen"
              && BABImport.presetSpec("Quarte_of_Bottom_Right")?.op == "quarterBottomRight"
              && BABImport.presetSpec("Openthe_ConnecttoServer_Window")?.op == "connectToServer"
              && BABImport.presetSpec("VolumeDown")?.delta == -6
              && BABImport.presetSpec("Open...") == nil)
        check("bab: every mapped preset op exists in ActionCatalog",
              BABImport.presetTable.values.allSatisfy { t in
                  switch t.0 {
                  case "window": return ActionCatalog.windowNames[t.1 ?? ""] != nil
                  case "snap":   return ActionCatalog.snapNames[t.1 ?? ""] != nil
                  case "system": return ActionCatalog.systemNames[t.1 ?? ""] != nil
                  default:       return true
                  }
              })
        check("bab: app groups (All Applications → default, bundle id kept, empty dropped)",
              Set(r.rulesets.keys) == ["default", "com.example.editor"])
        check("bab: corner ids",
              def["corner.topLeft.down"]?.type == "brightness" && (def["corner.topLeft.down"]?.delta ?? 0) < 0
              && def["corner.topLeft.down"]?.op == nil)
        // 触控板、妙控鼠标、键盘已移除：这些规则不导入，全部列进跳过清单
        let removedDevices = r.skipped.filter { [L("触控板"), L("妙控鼠标"), L("键盘")].contains($0.device) }
        check("bab: trackpad / magic mouse / keyboard rules are skipped, not imported",
              !def.keys.contains { $0.hasPrefix("trackpad.") || $0.hasPrefix("magicMouse.") || $0.hasPrefix("keyboard.") }
              && removedDevices.count == 8, "\(removedDevices.map(\.gesture))")
        let custom = def["twoKey.custom.1"]
        let glyph = r.customGlyphs["1"] ?? []
        check("bab: custom stroke imported as twoKey.custom (y flipped)",
              custom?.keyCode == 15 && glyph.count == 4 && glyph.first == CGPoint(x: 100, y: 0)
              && glyph[1] == CGPoint(x: 140, y: 60), "\(glyph)")
        check("bab: imported rule count", r.importedCount == 8, "\(r.importedCount)")
        let skippedGestures = Set(r.skipped.map(\.gesture))
        check("bab: unmappable rules go to the skipped list",
              r.skipped.count == 13
              && skippedGestures.isSuperset(of: [" BOf2Key", " ←Of3Key", " ↗Of2Key", " ↙Of2Key",
                                                 "2Finger_Swipe_Left", "3Finger_TipTap_Left", "Hover at Somewhere", "—"])
              && r.skipped.allSatisfy { !$0.reason.isEmpty && !$0.device.isEmpty },
              "\(r.skipped.map { "\($0.gesture):\($0.reason)" })")
        check("bab: skipped entry keeps original action", r.skipped.contains { $0.action == "NoSuchPreset" && $0.app == "com.example.editor" })
        let sum = BABImport.summary(r, maxLines: 3)
        check("bab: summary shows counts and first reasons",
              sum.contains("8") && sum.contains("13") && sum.components(separatedBy: "• ").count == 4
              && r.scriptLibraryCount == 2)

        // MARK: 修饰键 / 识别
        check("bab: modifier conversion drops device bits",
              BABImport.modifierFlags(NSNumber(value: 0x140109)) == 0x140000
              && BABImport.modifierFlags(NSNumber(value: 0x1C0000)) == 0x1C0000
              && BABImport.modifierFlags(nil) == 0)
        let json = try! JSONEncoder.pretty.encode(Config.defaultConfig)
        check("bab: preset detection",
              BABImport.looksLikePreset(url: URL(fileURLWithPath: "/x/a.BABPreset"), data: Data())
              && BABImport.looksLikePreset(url: nil, data: samplePreset(binary: true))
              && BABImport.looksLikePreset(url: nil, data: samplePreset())
              && !BABImport.looksLikePreset(url: URL(fileURLWithPath: "/x/r.json"), data: json))

        // MARK: 损坏 / 非预设文件
        func throwsError(_ d: Data) -> Bool {
            do { _ = try BABImport.parse(d); return false } catch { return !error.localizedDescription.isEmpty }
        }
        let good = samplePreset(binary: true)
        let plainPlist = try! PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .binary, options: 0)
        let noRules = FakeArchive().data(root: ["unrelated": "x"], binary: true)
        let arrayRoot = FakeArchive().data(root: ["x", "y"] as [Any], binary: true)
        check("bab: corrupt / non-preset files throw, no crash",
              throwsError(Data()) && throwsError(Data("garbage".utf8)) && throwsError(json)
              && throwsError(good.prefix(good.count / 2)) && throwsError(plainPlist)
              && throwsError(noRules) && throwsError(arrayRoot))
        // 自引用的对象图（恶意/损坏文件）不能死循环
        let loop: [String: Any] = ["$archiver": "NSKeyedArchiver", "$top": ["root": ["CF$UID": 1]],
                                   "$objects": ["$null", ["NS.objects": [["CF$UID": 1]]] as [String: Any]] as [Any]]
        let loopData = try! PropertyListSerialization.data(fromPropertyList: loop, format: .xml, options: 0)
        check("bab: cyclic object graph does not hang", throwsError(loopData))
        let badStroke = BABImport.customStroke(Data("x".utf8)) == nil && BABImport.customStroke(nil) == nil
        check("bab: unreadable custom stroke rejected", badStroke)

        // MARK: 合并 / 覆盖
        var current = Config.defaultConfig
        current.showHUD = false
        current.customGlyphs = ["1": [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 90)]]
        current.rulesets["default"]!.gestures["twoKey.custom.1"] =
            ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: nil, op: "sleep", delta: nil)
        let merged = BABImport.apply(r, to: current, mode: .merge)
        let mg = merged.rulesets["default"]!.gestures
        check("bab: merge keeps existing rules, preset wins on same gesture, glyph renamed",
              mg["twoKey.custom.1"]?.op == "sleep" && mg["twoKey.custom.2"]?.keyCode == 15
              && merged.customGlyphs?["2"]?.count == 4 && merged.customGlyphs?["1"]?.count == 2
              && mg["twoKey.key.a"]?.op == "minimizeAll" && mg["twoKey.up"]?.keyCode == 17
              && merged.rulesets["com.apple.Safari"] != nil && merged.showHUD == false)
        let replaced = BABImport.apply(r, to: current, mode: .replace)
        check("bab: replace swaps all rules but keeps settings",
              Set(replaced.rulesets.keys) == ["default", "com.example.editor"]
              && replaced.rulesets["default"]?.gestures["twoKey.key.a"] == nil
              && replaced.rulesets["default"]?.gestures["twoKey.custom.1"]?.keyCode == 15
              && replaced.customGlyphs?.count == 1 && replaced.showHUD == false)

        // MARK: 可选：用户桌面上的真实预设（只读；只断言数量，不输出内容）
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/2026-10-28-01-45-43.BABPreset")
        if let d = try? Data(contentsOf: real) {
            let n = (try? BABImport.parse(d))?.importedCount ?? 0
            check("bab: real desktop preset (optional, read-only) maps > 0 rules", n > 0, "\(n)")
        } else {
            check("bab: real desktop preset (optional, read-only) maps > 0 rules", true, "absent")
        }

        out += autoBackupChecks()
        return out
    }

    // MARK: - 自动备份轮换（临时目录）

    private static func autoBackupChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gk-autobackup-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        func list() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
        func day(_ n: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: n, hour: 12))!
        }

        check("autobackup: missing rules.json → no backup", ConfigIO.autoBackup(file, now: day(1)) == nil && list().isEmpty)

        try? Data("v1".utf8).write(to: file)
        let others = ["rules.backup-20260301-120000.json", "rules.broken-20260101-000000.json",
                      "rules.auto-notadate.json", "rules.auto-20260301.json.bak", "notes.txt"]
        for o in others { try? Data("keep".utf8).write(to: dir.appendingPathComponent(o)) }

        let first = ConfigIO.autoBackup(file, now: day(1))
        try? Data("v2".utf8).write(to: file)
        let second = ConfigIO.autoBackup(file, now: day(1))
        let copy = first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        check("autobackup: once per day, copies the pre-save content",
              first?.lastPathComponent == "rules.auto-20260301.json" && second == nil && copy == "v1",
              "\(list())")

        for d in 2...7 { ConfigIO.autoBackup(file, now: day(d)) }
        let autos = list().filter { ConfigIO.isAutoBackup($0, of: file) }
        check("autobackup: keeps the newest 5, deletes the oldest",
              autos == (3...7).map { String(format: "rules.auto-202603%02d.json", $0) }, "\(autos)")
        check("autobackup: never touches other files",
              others.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
              && (try? String(contentsOf: file, encoding: .utf8)) == "v2")
        check("autobackup: name filter",
              ConfigIO.isAutoBackup("rules.auto-20260101.json", of: file)
              && !ConfigIO.isAutoBackup("rules.auto-2026010.json", of: file)
              && !ConfigIO.isAutoBackup("rules.backup-20260101.json", of: file)
              && !ConfigIO.isAutoBackup("other.auto-20260101.json", of: file))
        return out
    }
}
