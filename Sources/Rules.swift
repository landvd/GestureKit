import Foundation

/// One action that a gesture can trigger.
///
/// type:
///   shortcut  按键合成（keyCode + modifiers）
///   window    最小化/恢复/全部/全屏（op）
///   snap      窗口布局（op = halfLeft/halfRight/halfTop/halfBottom/
///             quarterTopLeft/…/center/maximize）
///   system    系统动作（op = missionControl/showDesktop/launchpad/lockScreen/
///             sleep/emptyTrash/hideOthers/toggleDarkMode/spotlight/appSwitcher）
///   quitApp / volume / brightness
///   brightness 的 op：nil = 光标所在屏，external = 所有外接屏（DDC/CI），builtin = 内建屏
///   openApp   打开 / 切换到 App（bundleID 优先；找不到时用 path 指向的 .app 回退）
///   openURL   打开网址（http/https/mailto…）或本地文件/文件夹（url；以 / 或 ~ 开头视为路径，
///             无协议的 example.com 补 https://）
///   typeText  输入一段文字（text；换行按回车键发送）
///   runShortcut 运行「快捷指令」App 里的快捷指令（shortcutName；/usr/bin/shortcuts run，不等待）
///   window 的 op 另有 moveToNextSpace / moveToPrevSpace（实验）：把前台窗口移到相邻桌面空间
///
/// note    备注：HUD 优先显示它；只含空格 = 这条规则不提示
/// enabled false = 规则保留但不触发（设置表格里的「启用」复选框）
struct ActionSpec: Codable {
    var type: String
    var keyCode: Int?                // for shortcut
    var modifiers: UInt32?           // CGEventFlags raw value for shortcut
    var label: String?               // human readable, e.g. "⌘]"
    var op: String?                  // for window: minimize | restore | minimizeAll | restoreAll | fullscreen
    var delta: Double?               // for volume / brightness
    var note: String? = nil
    var enabled: Bool? = nil
    var bundleID: String? = nil      // for openApp
    var path: String? = nil          // for openApp: .app path (fallback when bundleID is not found)
    var url: String? = nil           // for openURL: URL or local path
    var text: String? = nil          // for typeText
    var shortcutName: String? = nil  // for runShortcut: name in the Shortcuts app
}

/// 双键手势时在屏幕上画出的轨迹。
struct TrailConfig: Codable, Equatable {
    var enabled: Bool = true
    var color: String = "#87D9FF"      // RGB hex
    var width: Double = 3              // 1…10 pt

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? color
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? width
    }
}

struct Ruleset: Codable {
    var gestures: [String: ActionSpec]
}

struct Config: Codable {
    var version: Int
    var enabled: Bool
    var minDistance: Double
    var cornerSize: Double
    /// Shape-gesture firing threshold (0…100). Original behaviour = 85.
    var shapeThreshold: Double?
    /// 黑名单：这些 App 在前台时整体暂停（bundle id）
    var blacklist: [String]?
    /// HUD：触发动作时在光标旁提示备注/动作名（默认开，停留 0.5s）
    var showHUD: Bool?
    var hudDuration: Double?
    /// 自定义绘图手势的模板笔画：name → 点（CG 坐标，y 向下）。
    /// 规则用 `twoKey.custom.<name>` 引用。
    var customGlyphs: [String: [CGPoint]]?
    /// 菜单栏图标（缺省显示）。隐藏后再次打开 App 会弹出设置窗口
    var showMenuBarIcon: Bool?
    /// 手势轨迹（缺省显示，浅蓝 3pt）
    var trail: TrailConfig?
    /// 界面语言："system"（缺省）/ "zh" / "en"（L10n.swift）。老配置没有这个键 → 跟随系统
    var language: String?
    /// 鼠标手势怎么起手："chord"（缺省，按住左右双键）/ "right"（按住右键画；
    /// 单击右键不画则松开时补发右键，菜单照常）。规则 id 两种方式通用（twoKey.*）。
    var gestureButton: String?
    /// 画了没认出来 / 被拦下时在光标旁提示（缺省开）
    var showUnrecognized: Bool?
    /// 从「手势记录」学到的个人笔画：手势 id → 若干笔（「我想画的是…」）。每个手势最多 5 笔。
    var learnedStrokes: [String: [[CGPoint]]]?
    /// 反例：手势 id → 用户说「不该触发」的笔画；与之相似的笔画不再触发该手势。每个最多 10 笔。
    var rejectedStrokes: [String: [[CGPoint]]]?
    var rulesets: [String: Ruleset]

    static func loadOrCreate() -> Config {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GestureKit", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rules.json")
        if let data = try? Data(contentsOf: url) {
            if let cfg = try? JSONDecoder().decode(Config.self, from: data) {
                let (slim, removed) = cfg.withoutRemovedFeatures()
                guard removed > 0 else { return cfg }
                // 一次性迁移：精简掉的功能（触控板 / 键盘触发 / 妙控鼠标 / 脚本 / 窗口吸附）留下的规则已不会触发
                ConfigIO.backup(url, tag: "before-slim")
                Log.write("config: removed \(removed) rule(s) of removed features (trackpad / keyboard / magic mouse / script)")
                save(slim)
                return slim
            }
            // 解析失败：先留一份坏文件，绝不直接覆盖用户数据
            let kept = ConfigIO.backup(url, tag: "broken")
            Log.write("rules.json unreadable, kept copy at \(kept?.path ?? "-"); using defaults")
        }
        let cfg = Config.defaultConfig
        if let data = try? JSONEncoder.pretty.encode(cfg) {
            try? data.write(to: url, options: .atomic)
        }
        return cfg
    }

    /// Rules that can no longer fire since trackpad gestures, keyboard triggers, Magic Mouse,
    /// the script library and window docking were removed. Returns the config without them and how many were dropped.
    func withoutRemovedFeatures() -> (Config, Int) {
        var c = self, removed = 0
        for (app, rs) in rulesets {
            let kept = rs.gestures.filter { id, spec in
                !id.hasPrefix("keyboard.") && !id.hasPrefix("magicMouse.") && !id.hasPrefix("trackpad.")
                    && spec.type != "script"
                    && !(spec.type == "window" && ["dockLeft", "dockRight"].contains(spec.op ?? ""))
            }
            removed += rs.gestures.count - kept.count
            c.rulesets[app] = Ruleset(gestures: kept)
        }
        return (c, removed)
    }

    static func save(_ config: Config) {
        // 每天第一次保存前留一份旧内容（rules.auto-yyyyMMdd.json，保留 5 份）
        ConfigIO.autoBackup(configURL)
        if let data = try? JSONEncoder.pretty.encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GestureKit/rules.json")
    }

    /// Seeded from the user's existing BetterAndBetter configuration.
    static var defaultConfig: Config {
        let cmd: UInt32 = 0x00100000          // .maskCommand
        let cmdCtrl: UInt32 = 0x00140000      // .maskCommand | .maskControl
        let cmdShift: UInt32 = 0x00120000

        func shortcut(_ key: Int, _ mods: UInt32, _ label: String) -> ActionSpec {
            ActionSpec(type: "shortcut", keyCode: key, modifiers: mods, label: label,
                       op: nil, delta: nil)
        }
        func noted(_ a: ActionSpec, _ note: String) -> ActionSpec { var a = a; a.note = note; return a }
        func window(_ op: String, _ label: String) -> ActionSpec {
            ActionSpec(type: "window", keyCode: nil, modifiers: nil, label: label,
                       op: op, delta: nil)
        }
        func volume(_ delta: Double) -> ActionSpec {
            ActionSpec(type: "volume", keyCode: nil, modifiers: nil, label: nil,
                       op: nil, delta: delta)
        }
        // 原版预设为 "External Screen Brightness"：只调外接屏
        func brightness(_ delta: Double) -> ActionSpec {
            ActionSpec(type: "brightness", keyCode: nil, modifiers: nil, label: nil,
                       op: "external", delta: delta)
        }

        let general = Ruleset(gestures: [
            // two-button drag directions
            // ← 后退 / → 前进（与浏览器 ⌘[ / ⌘] 一致）
            "twoKey.left":      noted(shortcut(33, cmd, "⌘["), "后退"),
            "twoKey.right":     noted(shortcut(30, cmd, "⌘]"), "前进"),
            "twoKey.upLeft":    window("restore", "恢复最小化"),
            "twoKey.downRight": window("minimize", "最小化"),
            "twoKey.upRight":   window("fullscreen", "全屏/退出全屏"),
            "twoKey.downLeft":  noted(shortcut(3, cmdCtrl, "⌃⌘F"), "退出全屏"),
            // 上下 ↑↓：刷新
            "twoKey.upThenDown": noted(shortcut(15, cmd, "⌘R"), "刷新"),
            // two-button + key
            "twoKey.key.a":     window("minimizeAll", "全部最小化"),
            "twoKey.key.v":     window("restoreAll", "恢复全部"),
            "twoKey.key.<":     ActionSpec(type: "quitApp", keyCode: nil, modifiers: nil,
                                           label: "退出当前 App", op: nil, delta: nil),
            // hot corners + scroll
            // 往上滚 = 调高 / 调亮
            "corner.topRight.up":       volume(6),
            "corner.topRight.down":     volume(-6),
            "corner.bottomLeft.up":     brightness(0.0625),
            "corner.bottomLeft.down":   brightness(-0.0625)
        ])

        let browser = Ruleset(gestures: [
            "twoKey.key.t":  shortcut(17, cmd, "⌘T"),
            "twoKey.key.f":  shortcut(13, cmd, "⌘W"),
            "twoKey.key.r":  shortcut(15, cmd, "⌘R"),
            "twoKey.left":   shortcut(33, cmd, "⌘["),
            "twoKey.right":  shortcut(30, cmd, "⌘]")
        ])

        return Config(version: 1, enabled: true, minDistance: 24, cornerSize: 40, shapeThreshold: 85,
                      blacklist: [], showHUD: true, hudDuration: 0.5,
                      rulesets: [
                        "default": general,
                        "com.apple.Safari": browser,
                        "com.citrolabs.ego.lite": browser
                      ])
    }
}

extension Config {
    /// 「音量每次调节」: one step size shared by every volume rule (corner scroll or gesture).
    static let volumeSteps: [Double] = [2, 4, 6, 8, 10, 15, 20]

    /// The step of the first volume rule found (the default top-right corner first); nil = none.
    var volumeStep: Double? {
        let all = rulesets.sorted { $0.key == "default" && $1.key != "default" }
            .flatMap { $0.value.gestures.sorted { $0.key < $1.key }.map(\.value) }
        return all.first { $0.type == "volume" && ($0.delta ?? 0) != 0 }.map { abs($0.delta!) }
    }

    /// Every volume rule set to `step`, keeping its direction.
    func settingVolumeStep(_ step: Double) -> Config {
        var c = self
        for (app, rs) in rulesets {
            for (id, spec) in rs.gestures where spec.type == "volume" {
                var s = spec
                s.delta = (spec.delta ?? 0) < 0 ? -step : step
                c.rulesets[app]?.gestures[id] = s
            }
        }
        return c
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
