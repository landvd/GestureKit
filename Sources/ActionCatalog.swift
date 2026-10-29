import Cocoa

/// Human-readable names for actions and keys, plus the list of actions the
/// rule editor offers. Shared by the HUD, the preferences table and the editor.
enum ActionCatalog {

    struct Choice: Identifiable {
        let id: String          // "type/op" (or "type/±" for volume/brightness)
        let category: String
        let title: String
        let spec: ActionSpec
    }

    // MARK: - Names
    // 名称表的值是中文原文，同时是 L10n 的 key；显示时一律经 L(...) 翻译
    // （见 title(for:) / choices）。存进 rules.json 的 label 保持中文原文。

    static let windowNames: [String: String] = [
        "minimize": "窗口最小化", "restore": "恢复最小化窗口",
        "minimizeAll": "全部最小化", "restoreAll": "恢复全部", "fullscreen": "窗口全屏",
        "enterFullScreen": "进入全屏", "exitFullScreen": "退出全屏", "zoom": "窗口缩放",
        "smartZoom": "智能缩放", "restorePrevious": "恢复上一次位置",
        "dockLeft": "吸附到左边缘", "dockRight": "吸附到右边缘",
        "moveToNextSpace": "移到下一个桌面（实验）", "moveToPrevSpace": "移到上一个桌面（实验）"
    ]

    static let snapNames: [String: String] = [
        "halfLeft": "左半屏", "halfRight": "右半屏", "halfTop": "上半屏",
        "halfBottom": "下半屏", "quarterTopLeft": "左上四分屏",
        "quarterTopRight": "右上四分屏", "quarterBottomLeft": "左下四分屏",
        "quarterBottomRight": "右下四分屏", "center": "居中", "maximize": "最大化",
        "maximizeWidth": "最大化宽度", "maximizeHeight": "最大化高度"
    ]

    static let systemNames: [String: String] = [
        "missionControl": "调度中心", "showDesktop": "显示桌面",
        "launchpad": "启动台", "lockScreen": "锁屏", "sleep": "睡眠",
        "emptyTrash": "清空废纸篓", "hideOthers": "隐藏其他 App",
        "toggleDarkMode": "深色/浅色模式", "spotlight": "聚焦搜索",
        "appSwitcher": "App 切换器",
        "playPause": "播放/暂停", "nextTrack": "下一首", "previousTrack": "上一首",
        "volumeUp": "音量加", "volumeDown": "音量减", "mute": "静音",
        "screenshotRegion": "区域截图", "screenshotWindow": "窗口截图",
        "screenshotFull": "全屏截图",
        "openHome": "打开个人目录", "openDocuments": "打开文稿",
        "openDownloads": "打开下载", "openDesktop": "打开桌面",
        "openApplications": "打开应用程序", "openRoot": "打开根目录",
        "newFinderWindow": "新 Finder 窗口",
        "nextScreen": "移到下一屏", "prevScreen": "移到上一屏",
        "newTab": "新标签", "closeTab": "关标签", "nextTab": "下一标签",
        "prevTab": "上一标签", "pageBack": "后退", "pageForward": "前进",
        "pageTop": "页首", "pageBottom": "页尾", "closeWindow": "关窗口",
        "toggleDock": "显示/隐藏 Dock",
        "hideDesktopFiles": "隐藏桌面文件", "showDesktopFiles": "显示桌面文件",
        "shutdown": "关机", "restart": "重启", "forceQuit": "强制退出",
        "toggleFnKeys": "Fn 键模式", "toggleWiFi": "WiFi 开关",
        "toggleBluetooth": "蓝牙开关", "switchInputSource": "切换输入法",
        "openSystemPreferences": "系统设置",
        "openSecurityPreferences": "安全性与隐私",
        "openAppPreferences": "GestureKit 设置", "quitGestureKit": "退出 GestureKit",
        "restartGestureKit": "重启 GestureKit",
        "previousApp": "上一个应用", "siri": "Siri",
        "hideAllButFinder": "隐藏除 Finder 外的 App", "unhideAll": "显示全部 App",
        "finderOpenSelected": "进入下一级目录", "finderEnclosing": "返回上一级目录",
        "finderTrashSelected": "删除所选到废纸篓", "finderNewFolder": "新建文件夹",
        "openNetwork": "打开网络", "openRecents": "打开最近使用", "openAirDrop": "打开隔空投送",
        "openICloudDrive": "打开 iCloud 云盘", "goToFolder": "前往文件夹", "connectToServer": "连接服务器",
        "darkMode": "深色模式", "lightMode": "浅色模式", "wifiOn": "打开 WiFi", "wifiOff": "关闭 WiFi",
        "bluetoothOn": "打开蓝牙", "bluetoothOff": "关闭蓝牙", "screenSaver": "屏幕保护程序",
        "keyboardBacklightUp": "键盘背光调亮", "keyboardBacklightDown": "键盘背光调暗",
        "keyboardBacklightMax": "键盘背光最亮", "keyboardBacklightMin": "关闭键盘背光",
        "keyboardBacklightMiddle": "键盘背光中等",
        "leftClick": "鼠标左键单击", "rightClick": "鼠标右键单击", "middleClick": "鼠标中键单击",
        "middleDown": "鼠标中键按下", "middleUp": "鼠标中键松开",
        "scrollLeft": "向左滚动", "scrollRight": "向右滚动", "emojiPicker": "表情与符号"
    ]

    /// Editor grouping for `system` ops; every key of `systemNames` appears exactly once.
    static let systemGroups: [(String, [String])] = [
        ("窗口", ["nextScreen", "prevScreen"]),
        ("标签/页面", ["newTab", "closeTab", "nextTab", "prevTab", "pageBack", "pageForward",
                    "pageTop", "pageBottom", "closeWindow"]),
        ("应用", ["appSwitcher", "previousApp", "hideOthers", "hideAllButFinder", "unhideAll", "forceQuit",
                "spotlight", "siri", "missionControl", "showDesktop", "launchpad", "toggleDock", "emojiPicker"]),
        ("Finder", ["finderOpenSelected", "finderEnclosing", "finderNewFolder", "finderTrashSelected",
                    "emptyTrash", "newFinderWindow", "openHome", "openDocuments", "openDownloads", "openDesktop",
                    "openApplications", "openRoot", "openICloudDrive", "openRecents", "openAirDrop",
                    "openNetwork", "goToFolder", "connectToServer", "hideDesktopFiles", "showDesktopFiles"]),
        ("系统", ["lockScreen", "screenSaver", "sleep", "shutdown", "restart", "toggleDarkMode", "darkMode",
                "lightMode", "toggleWiFi", "wifiOn", "wifiOff", "toggleBluetooth", "bluetoothOn", "bluetoothOff",
                "toggleFnKeys", "switchInputSource", "openSystemPreferences", "openSecurityPreferences"]),
        ("媒体", ["playPause", "nextTrack", "previousTrack", "volumeUp", "volumeDown", "mute",
                "keyboardBacklightUp", "keyboardBacklightDown", "keyboardBacklightMax",
                "keyboardBacklightMin", "keyboardBacklightMiddle"]),
        ("截图", ["screenshotRegion", "screenshotWindow", "screenshotFull"]),
        ("鼠标", ["leftClick", "rightClick", "middleClick", "middleDown", "middleUp", "scrollLeft", "scrollRight"]),
        ("GestureKit", ["openAppPreferences", "quitGestureKit", "restartGestureKit"])
    ]

    /// Action column text ("快捷键" for shortcuts; the key itself goes in its own column).
    static func title(for spec: ActionSpec) -> String {
        switch spec.type {
        case "shortcut":   return L("快捷键")
        case "window":     return windowNames[spec.op ?? ""].map { L($0) } ?? (spec.op ?? "")
        case "snap":       return snapNames[spec.op ?? ""].map { L($0) } ?? (spec.op ?? "")
        case "system":     return systemNames[spec.op ?? ""].map { L($0) } ?? (spec.op ?? "")
        case "quitApp":    return L("退出当前 App")
        case "volume":     return (spec.delta ?? 0) < 0 ? L("调低音量") : L("调高音量")
        case "brightness":
            let down = (spec.delta ?? 0) < 0
            switch spec.op ?? "" {
            case "external": return down ? L("调低外接屏亮度") : L("调高外接屏亮度")
            case "builtin":  return down ? L("调低内建屏亮度") : L("调高内建屏亮度")
            default:         return down ? L("调低亮度") : L("调高亮度")
            }
        case "openApp":
            return L("打开 %@", appName(bundleID: spec.bundleID, path: spec.path) ?? "App")
        case "openURL":
            guard let url = Actions.resolveURL(spec.url) else { return L("打开网址或文件") }
            if url.isFileURL { return L("打开文件 %@", clip(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)) }
            return L("打开网址 %@", clip(url.host ?? url.absoluteString))
        case "typeText":
            let first = (spec.text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return first.isEmpty ? L("输入文字") : L("输入文字 %@", clip(first, 16))
        case "runShortcut":
            let n = (spec.shortcutName ?? "").trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? L("运行快捷指令") : L("运行快捷指令 %@", clip(n))
        default:           return spec.type
        }
    }

    /// Display name of an app: the saved path's file name, else LaunchServices, else the bundle id.
    static func appName(bundleID: String?, path: String?) -> String? {
        if let p = path, !p.isEmpty {
            return ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        guard let bid = bundleID, !bid.isEmpty else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bid
    }

    /// Shorten for names / HUD: at most `max` characters, then "…".
    static func clip(_ s: String, _ max: Int = 28) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    /// Text the HUD shows: the note wins; a note of only spaces means "stay silent"
    /// (matches the hint under 通用设置 → 提示备注或动作). Nil = show nothing.
    static func hudText(for spec: ActionSpec) -> String? {
        if let note = spec.note, !note.isEmpty {
            return note.trimmingCharacters(in: .whitespaces).isEmpty ? nil : note
        }
        if spec.type == "shortcut" { return spec.label ?? L("快捷键") }
        return title(for: spec)
    }

    // MARK: - Editor choices

    static var choices: [Choice] {
        var out: [Choice] = []
        func add(_ cat: String, _ type: String, op: String? = nil, delta: Double? = nil, _ title: String) {
            let spec = ActionSpec(type: type, keyCode: nil, modifiers: nil, label: title,
                                  op: op, delta: delta)
            // spec.label 存中文原文（写进 rules.json，与界面语言无关）；显示名经 L 翻译
            out.append(Choice(id: choiceID(for: spec), category: L(cat), title: L(title), spec: spec))
        }
        for op in ["minimize", "restore", "minimizeAll", "restoreAll", "fullscreen", "enterFullScreen",
                   "exitFullScreen", "zoom", "smartZoom", "restorePrevious", "dockLeft", "dockRight",
                   "moveToNextSpace", "moveToPrevSpace"] {
            add("窗口", "window", op: op, windowNames[op]!)
        }
        for op in ["halfLeft", "halfRight", "halfTop", "halfBottom", "quarterTopLeft",
                   "quarterTopRight", "quarterBottomLeft", "quarterBottomRight", "center", "maximize",
                   "maximizeWidth", "maximizeHeight"] {
            add("窗口布局", "snap", op: op, snapNames[op]!)
        }
        add("应用", "quitApp", "退出当前 App")
        add("声音与亮度", "volume", delta: 6, "调高音量")
        add("声音与亮度", "volume", delta: -6, "调低音量")
        add("声音与亮度", "brightness", delta: 0.0625, "调高亮度")
        add("声音与亮度", "brightness", delta: -0.0625, "调低亮度")
        add("声音与亮度", "brightness", op: "external", delta: 0.0625, "调高外接屏亮度")
        add("声音与亮度", "brightness", op: "external", delta: -0.0625, "调低外接屏亮度")
        for (cat, ops) in systemGroups {
            for op in ops { add(cat, "system", op: op, systemNames[op] ?? op) }
        }
        return out
    }

    /// Stable id for matching a saved spec back to a choice: "type/op±".
    static func choiceID(for spec: ActionSpec) -> String {
        "\(spec.type)/\(spec.op ?? "")\(spec.delta.map { $0 < 0 ? "-" : "+" } ?? "")"
    }

    // MARK: - Keys

    static let keyNames: [Int: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑",
        49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
        6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        32: "U", 34: "I", 31: "O", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9",
        43: ",", 47: ".", 44: "/", 39: "'", 33: "[", 30: "]", 27: "-", 24: "=",
        41: ";", 42: "\\", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    /// "⌃⌥⇧⌘" + key name, e.g. "⌘]". `flags` is a CGEventFlags raw value.
    static func keyLabel(code: Int, flags: UInt64) -> String {
        var m = ""
        if flags & 0x00040000 != 0 { m += "⌃" }
        if flags & 0x00080000 != 0 { m += "⌥" }
        if flags & 0x00020000 != 0 { m += "⇧" }
        if flags & 0x00100000 != 0 { m += "⌘" }
        return m + (keyNames[code] ?? "key\(code)")
    }
}
