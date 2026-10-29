import Foundation

/// 多语言（P2-15，docs/modules/16-i18n.md）。
///
/// 表驱动、单文件：中文原文就是 key。`L("窗口最小化")` 在英文下返回
/// "Minimize Window"，中文下原样返回；英文表里缺这条时回退中文，并 `Log.write` 一次。
/// 带插值的句子用格式化形式：`L("导入 %d 条规则", n)`（key 与译文用同样的占位符）。
///
/// 语言来源（优先级从高到低）：
///   override  自检 / 调试强制（"zh" / "en"；SelfTest.run() 开头设为 "zh"）
///   setting   rules.json 的 `language`（"system" / "zh" / "en"，nil = system）
///   系统首选语言：以 zh 开头 → 中文，否则英文（`systemLanguages` 可注入）
///
/// 不用 .lproj / Localizable.strings：build.sh 只拷 Info.plist，保持 `swiftc Sources/*.swift`。
/// scripts/check-l10n.sh 会检查源码里每个 `L("…")` 字面量都在下面的英文表里——
/// 所以英文表必须保持「一行一条 `"key": "value",`」的格式。
enum L10n {
    enum Language: String { case zh, en }

    /// 强制语言（自检 / 调试）。nil = 不强制。
    static var override: String? { didSet { invalidate() } }
    /// 配置里的语言（`Config.language`）。nil / "system" / 未知值 = 跟随系统。
    static var setting: String? { didSet { invalidate() } }
    /// 系统首选语言列表（可注入，自检用）。
    static var systemLanguages: () -> [String] = { Locale.preferredLanguages } { didSet { invalidate() } }

    private static let lock = NSLock()
    private static var cached: Language?
    private static var reportedMissing = Set<String>()

    /// "zh" / "en" 原样；其余（nil、"system"、未知值）→ "system"。
    static func normalized(_ value: String?) -> String {
        switch value?.lowercased() {
        case "zh"?: return "zh"
        case "en"?: return "en"
        default: return "system"
        }
    }

    /// 跟随系统：首选语言以 zh 开头 → 中文，否则（含空列表）英文。
    static func systemLanguage(_ preferred: [String]) -> Language {
        (preferred.first?.lowercased().hasPrefix("zh") ?? false) ? .zh : .en
    }

    /// 纯函数：override > setting > 系统。
    static func resolve(override: String?, setting: String?, system: [String]) -> Language {
        for v in [override, setting] {
            switch normalized(v) {
            case "zh": return .zh
            case "en": return .en
            default: continue
            }
        }
        return systemLanguage(system)
    }

    static var current: Language {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let c = resolve(override: override, setting: setting, system: systemLanguages())
        cached = c
        return c
    }

    static var isEnglish: Bool { current == .en }

    private static func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// 翻译一条中文原文。英文缺译时回退中文（每个 key 只记一次日志）。
    static func tr(_ zh: String) -> String {
        guard current == .en else { return zh }
        if let s = en[zh] { return s }
        lock.lock()
        let first = reportedMissing.insert(zh).inserted
        lock.unlock()
        if first { Log.write("l10n: missing English for \"\(zh)\"") }
        return zh
    }

    static func hasEnglish(_ zh: String) -> Bool { en[zh] != nil }

    /// 拼接短语：中文直接相连，英文用空格（「三指」+「上滑」/ "Three-Finger" + "Swipe Up"）。
    static func join(_ parts: String...) -> String {
        parts.joined(separator: current == .en ? " " : "")
    }

    /// 是否含中文（CJK 统一表意文字、CJK 标点、全角符号）。自检用。
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x3000...0x303F).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                || (0xFF00...0xFFEF).contains($0.value)
        }
    }

    // MARK: - English table

    /// Core table + per-area tables (`L10n+<Area>.swift`), so areas can be
    /// translated independently. Later tables win on duplicate keys.
    static let en: [String: String] = [enCore, enImport, enActions]
        .reduce(into: [:]) { acc, t in acc.merge(t) { _, new in new } }

    // BEGIN-EN（一行一条；scripts/check-l10n.sh 依赖这个格式）
    static let enCore: [String: String] = [
        // 动作名（ActionCatalog）
        "快捷键": "Shortcut",
        "退出当前 App": "Quit Current App",
        "调低音量": "Volume Down",
        "调高音量": "Volume Up",
        "调低外接屏亮度": "External Brightness Down",
        "调高外接屏亮度": "External Brightness Up",
        "调低内建屏亮度": "Built-in Brightness Down",
        "调高内建屏亮度": "Built-in Brightness Up",
        "调低亮度": "Brightness Down",
        "调高亮度": "Brightness Up",
        "窗口最小化": "Minimize Window",
        "恢复最小化窗口": "Restore Minimized Window",
        "全部最小化": "Minimize All",
        "恢复全部": "Restore All",
        "窗口全屏": "Toggle Full Screen",
        "进入全屏": "Enter Full Screen",
        "退出全屏": "Exit Full Screen",
        "窗口缩放": "Zoom Window",
        "智能缩放": "Smart Zoom",
        "恢复上一次位置": "Restore Previous Position",
        "吸附到左边缘": "Dock to Left Edge",
        "吸附到右边缘": "Dock to Right Edge",
        "左半屏": "Left Half",
        "右半屏": "Right Half",
        "上半屏": "Top Half",
        "下半屏": "Bottom Half",
        "左上四分屏": "Top-Left Quarter",
        "右上四分屏": "Top-Right Quarter",
        "左下四分屏": "Bottom-Left Quarter",
        "右下四分屏": "Bottom-Right Quarter",
        "居中": "Center",
        "最大化": "Maximize",
        "最大化宽度": "Maximize Width",
        "最大化高度": "Maximize Height",
        "调度中心": "Mission Control",
        "显示桌面": "Show Desktop",
        "启动台": "Launchpad",
        "锁屏": "Lock Screen",
        "睡眠": "Sleep",
        "清空废纸篓": "Empty Trash",
        "隐藏其他 App": "Hide Other Apps",
        "深色/浅色模式": "Toggle Dark Mode",
        "聚焦搜索": "Spotlight",
        "App 切换器": "App Switcher",
        "播放/暂停": "Play/Pause",
        "下一首": "Next Track",
        "上一首": "Previous Track",
        "音量加": "Volume Up",
        "音量减": "Volume Down",
        "静音": "Mute",
        "区域截图": "Screenshot Area",
        "窗口截图": "Screenshot Window",
        "全屏截图": "Screenshot Screen",
        "打开个人目录": "Open Home",
        "打开文稿": "Open Documents",
        "打开下载": "Open Downloads",
        "打开桌面": "Open Desktop",
        "打开应用程序": "Open Applications",
        "打开根目录": "Open Root Folder",
        "新 Finder 窗口": "New Finder Window",
        "移到下一屏": "Move to Next Display",
        "移到上一屏": "Move to Previous Display",
        "新标签": "New Tab",
        "关标签": "Close Tab",
        "下一标签": "Next Tab",
        "上一标签": "Previous Tab",
        "后退": "Back",
        "前进": "Forward",
        "页首": "Page Top",
        "页尾": "Page Bottom",
        "关窗口": "Close Window",
        "显示/隐藏 Dock": "Show/Hide Dock",
        "隐藏桌面文件": "Hide Desktop Files",
        "显示桌面文件": "Show Desktop Files",
        "关机": "Shut Down",
        "重启": "Restart",
        "强制退出": "Force Quit",
        "Fn 键模式": "Toggle Fn Keys",
        "WiFi 开关": "Toggle Wi-Fi",
        "蓝牙开关": "Toggle Bluetooth",
        "切换输入法": "Switch Input Source",
        "系统设置": "System Settings",
        "安全性与隐私": "Privacy & Security",
        "GestureKit 设置": "GestureKit Settings",
        "退出 GestureKit": "Quit GestureKit",
        "重启 GestureKit": "Restart GestureKit",
        "上一个应用": "Previous App",
        "Siri": "Siri",
        "隐藏除 Finder 外的 App": "Hide All but Finder",
        "显示全部 App": "Show All Apps",
        "进入下一级目录": "Open Selected Folder",
        "返回上一级目录": "Enclosing Folder",
        "删除所选到废纸篓": "Move Selection to Trash",
        "新建文件夹": "New Folder",
        "打开网络": "Open Network",
        "打开最近使用": "Open Recents",
        "打开隔空投送": "Open AirDrop",
        "打开 iCloud 云盘": "Open iCloud Drive",
        "前往文件夹": "Go to Folder",
        "连接服务器": "Connect to Server",
        "深色模式": "Dark Mode",
        "浅色模式": "Light Mode",
        "打开 WiFi": "Turn Wi-Fi On",
        "关闭 WiFi": "Turn Wi-Fi Off",
        "打开蓝牙": "Turn Bluetooth On",
        "关闭蓝牙": "Turn Bluetooth Off",
        "屏幕保护程序": "Screen Saver",
        "键盘背光调亮": "Keyboard Backlight Up",
        "键盘背光调暗": "Keyboard Backlight Down",
        "键盘背光最亮": "Keyboard Backlight Max",
        "关闭键盘背光": "Keyboard Backlight Off",
        "键盘背光中等": "Keyboard Backlight Medium",
        "鼠标左键单击": "Left Click",
        "鼠标右键单击": "Right Click",
        "鼠标中键单击": "Middle Click",
        "鼠标中键按下": "Middle Button Down",
        "鼠标中键松开": "Middle Button Up",
        "向左滚动": "Scroll Left",
        "向右滚动": "Scroll Right",
        "表情与符号": "Emoji & Symbols",
        // 动作分类
        "窗口": "Window",
        "窗口布局": "Window Layout",
        "标签/页面": "Tabs & Pages",
        "应用": "Apps",
        "Finder": "Finder",
        "系统": "System",
        "媒体": "Media",
        "截图": "Screenshots",
        "鼠标": "Mouse",
        "GestureKit": "GestureKit",
        "声音与亮度": "Sound & Brightness",
        // 手势名（PrefModel.gestureName / touchGestureName）
        "所有应用程序": "All Applications",
        "左上角": "Top-Left Corner",
        "右上角": "Top-Right Corner",
        "左下角": "Bottom-Left Corner",
        "右下角": "Bottom-Right Corner",
        "%@滚轮向上": "%@ Scroll Up",
        "%@滚轮向下": "%@ Scroll Down",
        "按住右键 + 自定义图形 ": "Right Button + Custom Shape ",
        "按住右键 + ": "Right Button + ",
        "%@（%@）": "%@ (%@)",
        // 菜单栏 / 提示（AppDelegate）
        "GestureKit：等待「辅助功能」权限": "GestureKit: waiting for Accessibility permission",
        "启用": "Enabled",
        "偏好设置…": "Settings…",
        "打开配置文件…": "Open Config File…",
        "重新加载配置": "Reload Config",
        "授予辅助功能权限…": "Grant Accessibility Permission…",
        "开机自启": "Launch at Login",
        "配置已重新加载": "Config reloaded",
        "辅助功能权限已授权": "Accessibility permission is already granted",
        "登录项设置失败：%@": "Couldn't change login item: %@",
        "好": "OK",
        // 规则管理
        "取消": "Cancel",
        "合并": "Merge",
        "覆盖": "Replace",
        // 导入 / 导出 / 重置（ConfigIO / 规则管理）
        "不是有效的 GestureKit 规则文件（%@）": "Not a valid GestureKit rules file (%@)",
        "已导出": "Exported",
        "导出失败": "Export Failed",
        "导入失败": "Import Failed",
        "导入 %d 条规则": "Import %d Rules",
        "合并：保留现有规则，同一手势以导入文件为准。\n覆盖：用导入文件替换全部设置和规则。\n导入前会自动备份当前 rules.json。": "Merge: keep existing rules; the file wins for the same gesture.\nReplace: replace all settings and rules with the file.\nThe current rules.json is backed up first.",
        "重置全部设置和规则？": "Reset all settings and rules?",
        "将恢复出厂规则。当前 rules.json 会先备份到同一目录。": "Factory rules will be restored. The current rules.json is backed up to the same folder first.",
        "重置": "Reset",
        "已重置": "Reset Done",
        "备份：%@": "Backup: %@",
        "无": "none",
        "导入/导出": "Import / Export",
        "导入规则": "Import Rules",
        "导出规则": "Export Rules",
        "重置全部设置和规则": "Reset All Settings and Rules",
        // 按键识别（HIDMouse / Preferences）
        "%d 键": "%d buttons",
        "罗技设备：若侧键无反应，可能已被 Logi Options+ 接管，可在其中把按键恢复为「默认/系统」。": "Logitech device: if side buttons don't respond, Logi Options+ may have taken them over. Set them back to \"Default/System\" there.",
        "雷蛇设备：若侧键无反应，可能已被 Razer Synapse 接管。": "Razer device: if side buttons don't respond, Razer Synapse may have taken them over.",
        "蓝牙": "Bluetooth",
        "蓝牙（低功耗）": "Bluetooth LE",
        "内建": "Built-in",
        "虚拟设备": "Virtual",
        "未知设备": "Unknown Device",
        "已授权": "Granted",
        "未授权": "Denied",
        "未询问": "Not Asked",
        "左键": "Left",
        "右键": "Right",
        "中键": "Middle",
        "第 %d 键": "Button %d",
        "%@按下": "%@ Down",
        "%@松开": "%@ Up",
        "第 %d 个：按键号 %d → %@": "#%d: button number %d → %@",
        "共识别 %d 个键（含左键）": "%d buttons detected (including left)",
        "；设备声明 %d 个键，其余键可能被厂商驱动占用或只经 HID 厂商页上报": "; the device reports %d. The rest may be taken by a vendor driver or only sent via a vendor HID page",
        "按键识别": "Buttons",
        "手势设置": "Gestures",
        "鼠标硬件信息": "Mouse Hardware",
        "设备：": "Device:",
        "未检测到鼠标类设备": "No pointing device found",
        "产品型号：": "Product:",
        "制造商：": "Manufacturer:",
        "连接方式：": "Connection:",
        "产品 ID：": "Product ID:",
        "厂商 ID：": "Vendor ID:",
        "按键数：": "Buttons:",
        "鼠标按键信息": "Mouse Buttons",
        "请按下任意鼠标键": "Press any mouse button",
        "*单击鼠标按键，按键状态将在此处显示。若未正确识别，请点按下方手动适配按钮": "*Click a mouse button and its state appears here. If it isn't recognized, use Manual Mapping below",
        "未开启「辅助功能」权限：只能识别在本窗口内的点击": "No Accessibility permission: only clicks inside this window are detected",
        "鼠标按键手动适配": "Manual Button Mapping",
        "请依次按下鼠标上除左键以外的每个按键（右键、滚轮键、侧键…），每个键按一次，然后点「完成」。": "Press every button except the left one (right, wheel, side buttons…) once each, then click \"Done\".",
        "等待按键…": "Waiting for a button…",
        "完成": "Done",
        "手动适配": "Manual Mapping",
        "重新适配": "Map Again",
        "*第 6–8 键若无反应，可能被厂商驱动占用，或该键只经 HID 厂商页上报（需「输入监控」权限，当前未启用）": "*If buttons 6–8 don't respond, a vendor driver may own them, or they're only sent via a vendor HID page (needs Input Monitoring, not used)",
        // 设置窗口（Preferences）
        "触控板": "Trackpad",
        "妙控鼠标": "Magic Mouse",
        "普通鼠标": "Mouse",
        "键盘": "Keyboard",
        "边角触发": "Hot Corners",
        "黑名单": "Blacklist",
        "规则管理": "Rules",
        "通用设置": "General",
        "GestureKit：%@": "GestureKit %@",
        "手势规则": "Gesture Rules",
        "手势": "Gesture",
        "动作": "Action",
        "备注": "Note",
        "暂无规则，点左下角 + 添加": "No rules yet. Click + at the bottom left to add one",
        "启动 & 显示": "Startup & Display",
        "开机自启动": "Launch at login",
        "菜单栏显示图标": "Show icon in menu bar",
        "语言：": "Language:",
        "跟随系统": "System",
        "窗口吸附": "Window Docking",
        "鼠标手势": "Mouse Gestures",
        "上左": "Up-Left",
        "添加应用程序…": "Add Application…",
        "删除": "Delete",
        "删除「%@」的专属规则…": "Delete Rules for \"%@\"…",
        "删除「%@」的专属规则？": "Delete the rules for \"%@\"?",
        "这个应用的 %d 条专属规则会被删除，之后它沿用「所有应用程序」的规则。删除前会自动备份 rules.json。": "Its %d app-specific rules will be deleted; afterwards it uses the All Applications rules. rules.json is backed up first.",
        "选择一个应用程序，为它单独设置手势": "Choose an app to give it its own gestures",
        "添加": "Add",
        "无法添加": "Can't Add",
        "「%@」没有 Bundle ID。": "\"%@\" has no bundle ID.",
        "「%@」专属规则；这里没有的手势沿用「所有应用程序」的规则": "Rules for \"%@\"; gestures not listed here use the All Applications rules",
        "提示：「上右 ↑→」与字母 F 画法相同；两条都设置时触发「上右」": "Note: Up-Right ↑→ is drawn like the letter F; if both have rules, Up-Right fires",
        "提示：「下右 ↓→」与字母 L 画法相同；两条都设置时触发「下右」": "Note: Down-Right ↓→ is drawn like the letter L; if both have rules, Down-Right fires",
        "上右": "Up-Right",
        "下左": "Down-Left",
        "下右": "Down-Right",
        "上下": "Up-Down",
        "音量 %d%%": "Volume %d%%",
        "画手势时按住：": "Hold while drawing:",
        "左右双键": "Left + right buttons",
        "*按住右键：画完松开执行动作；只单击右键（没画）时右键菜单照常弹出\n*两种方式共用同一套手势规则，按住时按字母键的规则也照样可用": "*Right button: draw, release to run the action; a plain right click (no drawing) still opens the context menu\n*Both modes share the same gesture rules; letter-key rules work while holding, too",
        "拖动窗口到屏幕左/右边缘时自动吸附": "Dock windows dragged to the left/right screen edge",
        "*窗口滑到屏幕外只留 1 像素，鼠标碰到那条边就滑回来；把它拖离边缘即取消吸附\n*也可以在手势规则里用「吸附到左/右边缘」动作\n⚠️ macOS 15 起拖到边缘会触发系统平铺，开启前请在「系统设置 → 桌面与程序坞」关闭「将窗口拖到屏幕边缘以平铺」": "*The window slides off-screen leaving 1 pixel and slides back when the pointer touches that edge; drag it away from the edge to undock\n*You can also use the \"Dock to Left/Right Edge\" actions in rules\n⚠️ Since macOS 15, dragging to an edge tiles the window. Turn off \"Drag windows to screen edges to tile\" in System Settings → Desktop & Dock first",
        "提示信息": "Hints",
        "显示轨迹": "Show trail",
        "轨迹颜色：": "Trail color:",
        "轨迹宽度：": "Trail width:",
        "提示备注或动作": "Show note or action",
        "*1,优先提示备注,没有备注时提示执行动作\n2,⚠️如果备注仅仅是空格,将不提示这条规则": "*1. Shows the note if there is one, otherwise the action\n2. ⚠️ A note of only spaces hides the hint for that rule",
        "应用程序黑名单": "App Blacklist",
        "*当黑名单中的应用程序激活时，手势将暂停；切换到其它 App 自动恢复": "*Gestures pause while a blacklisted app is active and resume when you switch away",
        "暂无条目": "No entries",
        "添加当前前台 App": "Add Frontmost App",
        // 规则编辑面板（RuleEditor）
        "自定义绘图…": "Custom Drawing…",
        "添加规则": "Add Rule",
        "编辑规则": "Edit Rule",
        "应用程序：": "App:",
        "手势：": "Gesture:",
        "图形：": "Shape:",
        "动作：": "Action:",
        "快捷键…": "Shortcut…",
        "快捷键：": "Shortcut:",
        "请选择": "Choose…",
        "备注：": "Note:",
        "可选，HUD 优先显示备注": "Optional; the HUD shows the note first",
        "保存": "Save",
        "在此按住鼠标画出图形": "Hold the mouse button and draw a shape here",
        "*按住左右键画出同样的形状即可触发（一笔画，起笔方向要一致）": "*Hold left + right buttons and draw the same shape to trigger it (one stroke, same starting direction)",
        "图形太小，请画大一些（至少 30pt）": "Shape too small. Draw it bigger (at least 30 pt)",
        "请按下按键…": "Press keys…",
        "点击录制": "Click to Record",
        "该 App 已有这个手势的规则，保存将覆盖它。": "This app already has a rule for this gesture. Saving replaces it.",
        // 权限向导（PermissionWizard）
        "为什么需要「辅助功能」权限": "Why Accessibility Permission Is Needed",
        "GestureKit 需要监听鼠标按键、拖动与滚轮来识别手势，并通过辅助功能接口移动、缩放、全屏窗口。没有这项权限，手势不会生效。GestureKit 不联网、不收集任何数据。": "GestureKit watches mouse buttons, drags and the scroll wheel to recognize gestures, and uses the Accessibility API to move, resize and full-screen windows. Without this permission gestures won't work. GestureKit never goes online or collects any data.",
        "授权步骤": "Steps",
        "点击下方「打开系统设置」，进入「隐私与安全性 → 辅助功能」。": "Click \"Open System Settings\" below and go to Privacy & Security → Accessibility.",
        "在列表中找到 GestureKit，打开右侧开关（可能需要输入登录密码）。": "Find GestureKit in the list and turn on its switch (you may need your login password).",
        "如果列表里已有 GestureKit 但开关打开后仍不生效（重新编译或更新后常见）：选中旧条目点「−」删除，再点「+」添加 /Applications/GestureKit.app，或点「在访达中显示 GestureKit」后把它拖进列表。": "If GestureKit is listed and switched on but still doesn't work (common after a rebuild or update): select the old entry and click \"−\", then click \"+\" to add /Applications/GestureKit.app, or click \"Show GestureKit in Finder\" and drag it into the list.",
        "授权完成后无需重启，本窗口会自动检测并关闭。": "No restart needed. This window detects the change and closes itself.",
        "打开系统设置": "Open System Settings",
        "在访达中显示 GestureKit": "Show GestureKit in Finder",
        "当前程序位置：%@": "App location: %@",
        "可选：自动化（AppleScript）": "Optional: Automation (AppleScript)",
        "只有当你在动作里使用 AppleScript 控制其它 App 时才需要。首次运行这类脚本时系统会询问是否允许，按需同意即可；之后可在「隐私与安全性 → 自动化」中管理。": "Only needed when your actions use AppleScript to control other apps. macOS asks the first time such a script runs; allow it as needed. Manage it later in Privacy & Security → Automation.",
        "授予 GestureKit「辅助功能」权限": "Give GestureKit Accessibility Permission",
        "只需一次设置，鼠标手势即可开始工作": "Set it up once and mouse gestures start working",
        "正在等待授权…（每秒自动检测，已等待 %d 秒）": "Waiting for permission… (checking every second, %d s so far)",
        "已获得辅助功能权限，手势已启用。窗口即将关闭。": "Accessibility permission granted. Gestures are on. This window will close.",
        "已获得辅助功能权限，手势已启用。": "Accessibility permission granted. Gestures are on.",
        "GestureKit 权限向导": "GestureKit Permission Setup",
    ]
    // END-EN
}

/// 翻译：中文原文 → 当前语言。
func L(_ zh: String) -> String { L10n.tr(zh) }

/// 翻译 + 格式化：`L("导入 %d 条规则", n)`。占位符与 String(format:) 相同。
func L(_ zh: String, _ args: CVarArg...) -> String {
    String(format: L10n.tr(zh), arguments: args)
}
