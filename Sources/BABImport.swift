import Cocoa

/// Import of the original app's `.BABPreset` files (docs/modules/13-storage-sync.md).
///
/// A preset is an NSKeyedArchiver archive of the whole preferences dictionary. We do not
/// use NSKeyedUnarchiver: we walk the `$objects` / `$top` / `CF$UID` object graph ourselves
/// (plain dictionaries, arrays, strings, numbers, data, NSValue points), so nothing depends
/// on the original app's classes.
///
/// Rule groups we read: `ruleOfNormalMouse`, `ruleOfTrackPad`, `ruleOfMagicMouse`,
/// `ruleOfHotCorners`, `ruleOfKeyboard` — each an array of `{AppName, "All Rules": [...]}`;
/// every rule is `{Gesture, Action: {ActionType, Action}, Enable, Note}`.
/// Rules that cannot be mapped are reported in `skipped`, never silently dropped.
enum BABImport {

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Skipped {
        let device: String      // 普通鼠标 / 触控板 / …（已本地化）
        let app: String         // "default" or bundle id
        let gesture: String     // original gesture id (as text)
        let action: String      // original action (as text)
        let reason: String      // localized
    }

    struct Result {
        var rulesets: [String: Ruleset] = [:]
        var customGlyphs: [String: [CGPoint]] = [:]
        var skipped: [Skipped] = []
        /// Entries of the original script library (not rules; not imported).
        var scriptLibraryCount = 0
        var importedCount: Int { rulesets.values.reduce(0) { $0 + $1.gestures.count } }
    }

    // MARK: - Detection

    /// Extension `.BABPreset`, or a property list (binary/XML) that is a keyed archive.
    static func looksLikePreset(url: URL?, data: Data) -> Bool {
        if url?.pathExtension.lowercased() == "babpreset" { return true }
        if data.starts(with: Array("bplist".utf8)) { return true }
        let head = String(decoding: data.prefix(512), as: UTF8.self)
        return head.contains("<plist") && String(decoding: data.prefix(4096), as: UTF8.self)
            .contains("NSKeyedArchiver")
    }

    // MARK: - Parse

    static func parse(_ data: Data) throws -> Result {
        let root = try unarchiveRoot(data)
        guard let prefs = root as? [String: Any] else {
            throw ImportError(message: L("不是有效的 BetterAndBetter 预设文件（根对象不是字典）"))
        }
        let groups: [(String, String)] = [
            ("ruleOfNormalMouse", "normalMouse"), ("ruleOfTrackPad", "trackpad"),
            ("ruleOfMagicMouse", "magicMouse"), ("ruleOfHotCorners", "hotCorners"),
            ("ruleOfKeyboard", "keyboard")
        ]
        guard groups.contains(where: { prefs[$0.0] != nil }) else {
            throw ImportError(message: L("不是有效的 BetterAndBetter 预设文件（没有规则分组）"))
        }
        var res = Result()
        res.scriptLibraryCount = (prefs["ruleOfAppleScript"] as? [Any])?.count ?? 0
        for (key, device) in groups {
            for case let group as [String: Any] in (prefs[key] as? [Any]) ?? [] {
                let app = appKey(group)
                for case let rule as [String: Any] in (group["All Rules"] as? [Any]) ?? [] {
                    importRule(rule, device: device, app: app, into: &res)
                }
            }
        }
        // 空分组不留在配置里
        res.rulesets = res.rulesets.filter { !$0.value.gestures.isEmpty }
        return res
    }

    static func deviceName(_ device: String) -> String {
        switch device {
        case "normalMouse": return L("普通鼠标")
        case "trackpad":    return L("触控板")
        case "magicMouse":  return L("妙控鼠标")
        case "hotCorners":  return L("边角触发")
        case "keyboard":    return L("键盘")
        default:            return device
        }
    }

    /// "All Applications" → default; otherwise the bundle id the group names.
    static func appKey(_ group: [String: Any]) -> String {
        for k in ["BundleID", "bundleID", "BundleIdentifier", "bundleIdentifier"] {
            if let s = group[k] as? String, !s.isEmpty { return s }
        }
        let name = (group["AppName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.caseInsensitiveCompare("All Applications") == .orderedSame { return "default" }
        return name
    }

    private static func importRule(_ rule: [String: Any], device: String, app: String, into res: inout Result) {
        let gestureText = describe(rule["Gesture"])
        let actionDict = rule["Action"] as? [String: Any] ?? [:]
        let actionText = describeAction(actionDict)
        func skip(_ reason: String) {
            res.skipped.append(Skipped(device: deviceName(device), app: app, gesture: gestureText,
                                       action: actionText, reason: reason))
        }

        // 手势
        var glyph: [CGPoint]?
        let gid: String
        switch mapGesture(rule["Gesture"], device: device, data: rule["Data"]) {
        case .failure(let reason): skip(reason.text); return
        case .success(let g): gid = g.id; glyph = g.stroke
        }

        // 动作
        var spec: ActionSpec
        switch mapAction(actionDict) {
        case .failure(let reason): skip(reason.text); return
        case .success(let s): spec = s
        }

        // 启用 / 备注
        if !isEnabled(rule["Enable"]) { spec.enabled = false }
        if let note = rule["Note"] as? String, !note.isEmpty { spec.note = note }

        var gestures = res.rulesets[app]?.gestures ?? [:]
        var finalID = gid
        if let stroke = glyph {
            var n = res.customGlyphs.count + 1
            while res.customGlyphs["\(n)"] != nil { n += 1 }
            res.customGlyphs["\(n)"] = stroke
            finalID = GlyphLibrary.customPrefix + "\(n)"
        }
        guard gestures[finalID] == nil else {
            skip(L("与同一 App 里的另一条规则对应到同一个手势"))
            return
        }
        gestures[finalID] = spec
        res.rulesets[app] = Ruleset(gestures: gestures)
    }

    static func isEnabled(_ v: Any?) -> Bool {
        switch v {
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            return !(t == "0" || t == "no" || t == "false")
        default: return true
        }
    }

    // MARK: - Gesture mapping

    struct MappedGesture { let id: String; var stroke: [CGPoint]? = nil }

    private static let arrowIDs: [String: String] = [
        "←": "left", "→": "right", "↑": "up", "↓": "down",
        "↖": "upLeft", "↗": "upRight", "↙": "downLeft", "↘": "downRight"
    ]
    private static let reversedArrow: [String: String] = [
        "←": "→", "→": "←", "↑": "↓", "↓": "↑", "↖": "↘", "↘": "↖", "↗": "↙", "↙": "↗"
    ]

    static func mapGesture(_ g: Any?, device: String, data: Any? = nil) -> Swift.Result<MappedGesture, SkipReason> {
        // 触控板、妙控鼠标、键盘触发已从 GestureKit 移除：这几组规则如实列入「跳过」
        if device == "keyboard" || device == "magicMouse" || device == "trackpad" {
            return .failure(SkipReason(L("GestureKit 不支持%@规则", deviceName(device))))
        }
        guard let s = g as? String, !s.isEmpty else { return .failure(SkipReason(L("空规则（没有设置手势）"))) }
        switch device {
        case "normalMouse": return mapMouseGesture(s, data: data)
        case "hotCorners":  return mapCorner(s)
        default: return .failure(SkipReason(L("暂不支持这类手势")))
        }
    }

    /// `" ←Of2Key"`, `"!TOf2Key"`, `"CustomizeOf2Key"` (+ Data).
    private static func mapMouseGesture(_ s: String, data: Any?) -> Swift.Result<MappedGesture, SkipReason> {
        guard s.hasSuffix("Key"), let ofRange = s.range(of: "Of", options: .backwards) else {
            return .failure(SkipReason(L("暂不支持这类手势")))
        }
        let keys = Int(s[ofRange.upperBound..<s.index(s.endIndex, offsetBy: -3)]) ?? 0
        guard keys == 2 else { return .failure(SkipReason(L("暂只支持双键手势（原为 %d 键）", keys))) }
        let head = String(s[..<ofRange.lowerBound])
        if head == "Customize" {
            guard let stroke = customStroke(data) else {
                return .failure(SkipReason(L("自定义笔画无法读取")))
            }
            return .success(MappedGesture(id: GlyphLibrary.customPrefix, stroke: stroke))
        }
        guard let first = head.first, first == " " || first == "!", head.count == 2 else {
            return .failure(SkipReason(L("暂不支持这类手势")))
        }
        let reversed = first == "!"
        var glyph = String(head.dropFirst())
        if arrowIDs[glyph] != nil {
            if reversed { glyph = reversedArrow[glyph]! }
            return .success(MappedGesture(id: "twoKey." + arrowIDs[glyph]!))
        }
        let upper = glyph.uppercased()
        guard GlyphLibrary.template(for: upper) != nil else {
            return .failure(SkipReason(L("GestureKit 暂无字形「%@」", glyph)))
        }
        return .success(MappedGesture(id: "twoKey.key." + (upper == "<" || upper == ">" ? upper : upper.lowercased())))
    }

    /// `Scroll Up at TopRight Corner` → `corner.topRight.up`.
    private static func mapCorner(_ s: String) -> Swift.Result<MappedGesture, SkipReason> {
        let parts = s.split(separator: " ").map(String.init)
        let corners = ["TopLeft": "topLeft", "TopRight": "topRight",
                       "BottomLeft": "bottomLeft", "BottomRight": "bottomRight"]
        guard parts.count == 5, parts[0] == "Scroll", parts[2] == "at", parts[4] == "Corner",
              let dir = ["Up": "up", "Down": "down"][parts[1]], let corner = corners[parts[3]] else {
            return .failure(SkipReason(L("暂不支持这类边角手势")))
        }
        return .success(MappedGesture(id: "corner.\(corner).\(dir)"))
    }

    /// NSEvent.ModifierFlags → CGEventFlags raw value. ⇧⌃⌥⌘ use the same bits in both
    /// (0x20000 / 0x40000 / 0x80000 / 0x100000); the low device-dependent bits are dropped.
    static func modifierFlags(_ v: Any?) -> UInt32 {
        let raw = (v as? NSNumber)?.uint64Value ?? 0
        let ns = NSEvent.ModifierFlags(rawValue: UInt(raw))
        var cg: CGEventFlags = []
        if ns.contains(.shift)   { cg.insert(.maskShift) }
        if ns.contains(.control) { cg.insert(.maskControl) }
        if ns.contains(.option)  { cg.insert(.maskAlternate) }
        if ns.contains(.command) { cg.insert(.maskCommand) }
        return UInt32(cg.rawValue)
    }

    /// Nested archive (`Data`) holding an array of NSValue points (screen coords, y up)
    /// → our template points (y down, like recorded custom strokes).
    static func customStroke(_ data: Any?) -> [CGPoint]? {
        guard let d = data as? Data, let root = try? unarchiveRoot(d), let arr = root as? [Any] else { return nil }
        let pts = arr.compactMap { $0 as? CGPoint }
        guard pts.count >= 2, RuleDraft.isUsableStroke(pts) else { return nil }
        let maxY = pts.map(\.y).max()!
        return pts.map { CGPoint(x: $0.x, y: maxY - $0.y) }
    }

    // MARK: - Action mapping

    struct SkipReason: Error { let text: String; init(_ t: String) { text = t } }

    static func mapAction(_ a: [String: Any]) -> Swift.Result<ActionSpec, SkipReason> {
        let type = (a["ActionType"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        switch type {
        case "Shortcut Keys":
            guard let d = a["Action"] as? [String: Any], let code = (d["keyCode"] as? NSNumber)?.intValue else {
                return .failure(SkipReason(L("快捷键缺少按键")))
            }
            let mods = modifierFlags(d["modifierFlags"])
            return .success(ActionSpec(type: "shortcut", keyCode: code, modifiers: mods,
                                       label: ActionCatalog.keyLabel(code: code, flags: UInt64(mods)),
                                       op: nil, delta: nil))
        case "Preset":
            let name = a["Action"] as? String ?? ""
            guard let spec = presetSpec(name) else {
                return .failure(SkipReason(L("GestureKit 暂无对应的预设动作")))
            }
            return .success(spec)
        case "":
            return .failure(SkipReason(L("空规则（没有设置动作）")))
        default:
            return .failure(SkipReason(L("暂不支持这类动作（%@）", type)))
        }
    }

    /// Preset names appear with and without spaces/underscores and in mixed case
    /// ("Open a New Tab" / "OpenaNewTab", "half_of_Left" / "Half_of_Left"): compare
    /// lowercased letters and digits only.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .map(Character.init))
    }

    /// Normalized preset name → (type, op, delta). See docs/RE_MODULES.md §6.2.
    static let presetTable: [String: (String, String?, Double?)] = {
        var t: [String: (String, String?, Double?)] = [:]
        func w(_ op: String, _ names: String...) { for n in names { t[n] = ("window", op, nil) } }
        func s(_ op: String, _ names: String...) { for n in names { t[n] = ("snap", op, nil) } }
        func y(_ op: String, _ names: String...) { for n in names { t[n] = ("system", op, nil) } }
        // 窗口
        w("minimize", "minimization")
        w("restore", "minimizationrecovery")
        w("minimizeAll", "allminimization")
        w("restoreAll", "minimizationallrecovery")
        w("fullscreen", "windowenterexitfullscreen")
        w("enterFullScreen", "fullscreen", "enterfullscreen")
        w("exitFullScreen", "exitfullscreen")
        w("zoom", "windowzoom", "zoom")
        w("smartZoom", "smartzoom")
        w("restorePrevious", "restorethepreviousposition")
        w("dockLeft", "adsorbentwindowatleft")
        w("dockRight", "adsorbentwindowatright")
        // 布局
        s("maximize", "maximization")
        s("maximizeWidth", "maxofwidth")
        s("maximizeHeight", "maxofheight")
        s("center", "center")
        s("halfTop", "halfoftop"); s("halfBottom", "halfofbottom")
        s("halfLeft", "halfofleft"); s("halfRight", "halfofright")
        s("quarterTopLeft", "quarteoftopleft", "quarteroftopleft")
        s("quarterTopRight", "quarteoftopright", "quarteroftopright")
        s("quarterBottomLeft", "quarteofbottomleft", "quarterofbottomleft")
        s("quarterBottomRight", "quarteofbottomright", "quarterofbottomright")
        y("nextScreen", "movewindowtonextscreen")
        y("prevScreen", "movewindowtoprescreen", "movewindowtopreviousscreen")
        // 标签 / 页面
        y("newTab", "openanewtab"); y("closeTab", "closethetab")
        y("nextTab", "nexttab"); y("prevTab", "previoustab")
        y("pageBack", "pageback"); y("pageForward", "pageforward")
        y("pageTop", "pagetop"); y("pageBottom", "pagebottom")
        y("closeWindow", "closethewindow")
        // 应用 / 系统
        t["exit"] = ("quitApp", nil, nil)
        y("appSwitcher", "applicationswitcher"); y("previousApp", "previousapplication")
        y("forceQuit", "forcequittheapplication"); y("spotlight", "spotlight"); y("siri", "siri")
        y("missionControl", "missioncontrol"); y("launchpad", "launchpad")
        y("toggleDock", "showhidethedock")
        y("hideAllButFinder", "hideallappsexceptfinder"); y("unhideAll", "unhideallapplications")
        // Finder
        y("finderOpenSelected", "enterthenextfinderdirectory")
        y("finderEnclosing", "returntothepreviousfinderdirectory")
        y("finderNewFolder", "createanewfolder")
        y("finderTrashSelected", "deleteselecteditemstotrash")
        y("emptyTrash", "emptythetrash")
        y("newFinderWindow", "openanewfinderwindow")
        y("openHome", "openuserfolder"); y("openDocuments", "opendocumentfolder")
        y("openDownloads", "opendownloadfolder"); y("openRoot", "openrootfolder")
        y("openApplications", "opentheapplicationfolder")
        y("openNetwork", "openthenetworkwindow"); y("openRecents", "opentherecentlyusedwindow")
        y("goToFolder", "openthegotofolderwindow"); y("openICloudDrive", "openicloudfolder")
        y("openAirDrop", "opentheairdropwindow"); y("connectToServer", "opentheconnecttoserverwindow")
        y("showDesktopFiles", "showalldesktopfiles"); y("hideDesktopFiles", "hidealldesktopfiles")
        // 开关
        y("darkMode", "darkmode"); y("lightMode", "lightmode")
        y("wifiOn", "turnonwifi"); y("wifiOff", "turnoffwifi")
        y("bluetoothOn", "turnonbluetooth"); y("bluetoothOff", "turnoffbluetooth")
        y("lockScreen", "lockscreen"); y("screenSaver", "screensaver"); y("sleep", "sleep")
        y("shutdown", "shutdown"); y("restart", "restart")
        y("switchInputSource", "chineseenglishimconversion")
        y("toggleFnKeys", "switchbetweenf1f2andapplefunctions")
        // 媒体 / 亮度
        t["volumeup"] = ("volume", nil, 6); t["volumedown"] = ("volume", nil, -6)
        t["brightnessup"] = ("brightness", nil, 0.0625); t["brightnessdown"] = ("brightness", nil, -0.0625)
        t["externalscreenbrightnessup"] = ("brightness", "external", 0.0625)
        t["externalscreenbrightnessdown"] = ("brightness", "external", -0.0625)
        y("mute", "mute"); y("playPause", "playpause")
        y("nextTrack", "nexttrack"); y("previousTrack", "previoustrack")
        y("keyboardBacklightUp", "keyboardbrightnessup"); y("keyboardBacklightDown", "keyboardbrightnessdown")
        y("keyboardBacklightMax", "maxkeyboardbrightness"); y("keyboardBacklightMin", "minkeyboardbrightness")
        y("keyboardBacklightMiddle", "middlekeyboardbrightness")
        // 输入 / 截图 / 其它
        y("leftClick", "leftmouseclick"); y("rightClick", "rightmouseclick")
        y("middleClick", "middlemouseclick"); y("middleDown", "middlemousedown"); y("middleUp", "middlemouseup")
        y("scrollLeft", "scrollleft"); y("scrollRight", "scrollright")
        y("emojiPicker", "insertemoticon")
        y("screenshotWindow", "singlewindowscreenshots"); y("screenshotRegion", "regionalscreenshots")
        y("openSystemPreferences", "opensystempreferences")
        y("openSecurityPreferences", "opensecurityandprivacysettings")
        y("openAppPreferences", "openapppreferences", "betterandbetterpreferences")
        y("quitGestureKit", "exitbetterandbetter")
        y("restartGestureKit", "restartbetterandbetter")
        return t
    }()

    static func presetSpec(_ name: String) -> ActionSpec? {
        guard let (type, op, delta) = presetTable[normalize(name)] else { return nil }
        var spec = ActionSpec(type: type, keyCode: nil, modifiers: nil, label: nil, op: op, delta: delta)
        switch type {
        case "window": spec.label = op.flatMap { ActionCatalog.windowNames[$0] }
        case "snap":   spec.label = op.flatMap { ActionCatalog.snapNames[$0] }
        case "system": spec.label = op.flatMap { ActionCatalog.systemNames[$0] }
        case "quitApp": spec.label = "退出当前 App"
        default: break
        }
        return spec
    }

    // MARK: - Apply

    /// merge: rules added on top of `current` (same gesture → preset wins).
    /// replace: all rules replaced by the preset. Global settings are always kept —
    /// a preset carries no GestureKit settings.
    static func apply(_ r: Result, to current: Config, mode: ConfigIO.ImportMode) -> Config {
        var glyphs: [String: [CGPoint]] = mode == .merge ? (current.customGlyphs ?? [:]) : [:]
        var rename: [String: String] = [:]
        for name in r.customGlyphs.keys.sorted(by: { (Int($0) ?? 0, $0) < (Int($1) ?? 0, $1) }) {
            var n = 1
            while glyphs["\(n)"] != nil { n += 1 }
            glyphs["\(n)"] = r.customGlyphs[name]
            rename[GlyphLibrary.customPrefix + name] = GlyphLibrary.customPrefix + "\(n)"
        }
        var imported: [String: Ruleset] = [:]
        for (app, rs) in r.rulesets {
            var g: [String: ActionSpec] = [:]
            for (id, spec) in rs.gestures { g[rename[id] ?? id] = spec }
            imported[app] = Ruleset(gestures: g)
        }
        var c = current
        if mode == .replace { c.rulesets = [:] }
        for (app, rs) in imported {
            var gestures = c.rulesets[app]?.gestures ?? [:]
            for (id, spec) in rs.gestures { gestures[id] = spec }
            c.rulesets[app] = Ruleset(gestures: gestures)
        }
        c.customGlyphs = glyphs.isEmpty ? nil : glyphs
        c.pruneCustomGlyphs()
        if c.customGlyphs?.isEmpty == true { c.customGlyphs = nil }
        return c
    }

    /// Text for the confirmation alert: counts + the first few skip reasons.
    static func summary(_ r: Result, maxLines: Int = 6) -> String {
        var lines = [L("可导入 %d 条规则，跳过 %d 条。", r.importedCount, r.skipped.count)]
        if !r.skipped.isEmpty {
            lines.append(L("跳过的规则："))
            for s in r.skipped.prefix(maxLines) {
                lines.append("• [\(s.device)] \(s.gesture) → \(s.action)：\(s.reason)")
            }
            if r.skipped.count > maxLines { lines.append(L("……另有 %d 条", r.skipped.count - maxLines)) }
        }
        if r.scriptLibraryCount > 0 {
            lines.append(L("原版脚本库（%d 个）不会导入。", r.scriptLibraryCount))
        }
        return lines.joined(separator: "\n")
    }

    /// Full list of skipped rules (for the「查看跳过列表」button).
    static func skippedReport(_ r: Result) -> String {
        r.skipped.map { s in
            let app = s.app == "default" ? L("所有应用程序") : s.app
            return "[\(s.device) · \(app)] \(s.gesture) → \(s.action)\n    \(s.reason)"
        }.joined(separator: "\n")
    }

    // MARK: - Text for skipped rules

    static func describe(_ g: Any?) -> String {
        switch g {
        case let s as String: return s.trimmingCharacters(in: .whitespaces).isEmpty ? "—" : s
        case let d as [String: Any]:
            guard let code = (d["keyCode"] as? NSNumber)?.intValue else { return "—" }
            return ActionCatalog.keyLabel(code: code, flags: UInt64(modifierFlags(d["modifierFlags"])))
        default: return "—"
        }
    }

    static func describeAction(_ a: [String: Any]) -> String {
        let type = a["ActionType"] as? String ?? ""
        if let name = a["Action"] as? String, !name.isEmpty { return name }
        if let d = a["Action"] as? [String: Any], let code = (d["keyCode"] as? NSNumber)?.intValue {
            return ActionCatalog.keyLabel(code: code, flags: UInt64(modifierFlags(d["modifierFlags"])))
        }
        return type.isEmpty ? "—" : type
    }

    // MARK: - Keyed-archive object graph

    /// Reads a binary/XML plist written by NSKeyedArchiver and returns `$top.root`
    /// as plain Swift values (dictionaries, arrays, strings, numbers, Data, Date, CGPoint).
    static func unarchiveRoot(_ data: Data) throws -> Any {
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ImportError(message: L("不是有效的 BetterAndBetter 预设文件（无法读取）"))
        }
        guard let top = plist as? [String: Any],
              (top["$archiver"] as? String) == "NSKeyedArchiver",
              let objects = top["$objects"] as? [Any],
              let tops = top["$top"] as? [String: Any],
              let rootRef = tops["root"] ?? tops.values.first else {
            throw ImportError(message: L("不是有效的 BetterAndBetter 预设文件（不是归档）"))
        }
        var g = ObjectGraph(objects: objects)
        guard let root = g.resolve(rootRef, depth: 0) else {
            throw ImportError(message: L("不是有效的 BetterAndBetter 预设文件（不是归档）"))
        }
        return root
    }

    /// `CF$UID` reference → index. Binary plists give CFKeyedArchiverUID objects;
    /// some writers leave `{"CF$UID": n}` dictionaries.
    static func uid(_ v: Any) -> Int? {
        if let d = v as? [String: Any], d.count == 1, let n = d["CF$UID"] as? NSNumber { return n.intValue }
        let obj = v as AnyObject
        guard (CFCopyTypeIDDescription(CFGetTypeID(obj)) as String) == "CFKeyedArchiverUID" else { return nil }
        // 公开 API 拿不到 UID 的值；它的描述固定以 "{value = N}" 结尾
        let text = String(describing: obj)
        guard let r = text.range(of: "value = ") else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }

    private struct ObjectGraph {
        let objects: [Any]
        var cache: [Int: Any] = [:]

        mutating func resolve(_ v: Any, depth: Int) -> Any? {
            guard depth < 64 else { return nil }           // 防循环引用
            if let i = BABImport.uid(v) {
                guard i >= 0, i < objects.count else { return nil }
                if let hit = cache[i] { return hit }
                let out = decode(objects[i], depth: depth + 1)
                if let out { cache[i] = out }
                return out
            }
            return decode(v, depth: depth + 1)
        }

        private mutating func decode(_ v: Any, depth: Int) -> Any? {
            if let s = v as? String { return s == "$null" ? nil : s }
            guard let d = v as? [String: Any] else { return v }      // number / data / date
            if let keys = d["NS.keys"] as? [Any], let vals = d["NS.objects"] as? [Any] {
                var out: [String: Any] = [:]
                for (k, val) in zip(keys, vals) {
                    guard let key = resolve(k, depth: depth) else { continue }
                    if let value = resolve(val, depth: depth) { out["\(key)"] = value }
                }
                return out
            }
            if let vals = d["NS.objects"] as? [Any] { return vals.compactMap { resolve($0, depth: depth) } }
            if let s = d["NS.string"] { return resolve(s, depth: depth) }
            if let data = d["NS.data"] ?? d["NS.bytes"] { return resolve(data, depth: depth) }
            if let p = d["NS.pointval"] {
                guard let s = resolve(p, depth: depth) as? String else { return nil }
                return NSPointFromString(s)
            }
            if let t = d["NS.time"] as? NSNumber { return Date(timeIntervalSinceReferenceDate: t.doubleValue) }
            if d["$classname"] != nil { return nil }       // class description, not a value
            var out: [String: Any] = [:]
            for (k, val) in d where k != "$class" {
                if let value = resolve(val, depth: depth) { out[k] = value }
            }
            return out
        }
    }
}
