import Foundation

// Actions 区域的英文表。格式同 L10n.swift：一行一条 `"中文原文": "English",`，
// 放在 BEGIN-EN / END-EN 之间（scripts/check-l10n.sh 依赖）。
extension L10n {
    // BEGIN-EN
    static let enActions: [String: String] = [
        // 新动作类型（ActionCatalog / RuleEditor）
        "移到下一个桌面（实验）": "Move to Next Space (Experimental)",
        "移到上一个桌面（实验）": "Move to Previous Space (Experimental)",
        "打开 %@": "Open %@",
        "打开网址或文件": "Open URL or File",
        "打开文件 %@": "Open File %@",
        "打开网址 %@": "Open URL %@",
        "输入文字": "Type Text",
        "输入文字 %@": "Type Text %@",
        "运行快捷指令": "Run Shortcut",
        "运行快捷指令 %@": "Run Shortcut %@",
        "打开 App…": "Open App…",
        "打开网址或文件…": "Open URL or File…",
        "输入文字…": "Type Text…",
        "运行快捷指令…": "Run Shortcut…",
        "App：": "App:",
        "选择…": "Choose…",
        "已在运行时切换到它，否则打开（%@）": "Switches to it if running, otherwise launches it (%@)",
        "地址：": "Address:",
        "https://…、mailto:…，或文件/文件夹路径": "https://…, mailto:…, or a file/folder path",
        "选择文件…": "Choose File…",
        "无法识别的地址": "Unrecognized address",
        "文字：": "Text:",
        "触发时在当前光标处输入这段文字；换行会按回车键发送": "Types this text at the cursor; line breaks are sent as Return",
        "快捷指令：": "Shortcut:",
        "快捷指令名称": "Shortcut name",
        "从列表选择": "Pick from List",
        "正在读取快捷指令列表…": "Reading shortcuts…",
        "读取快捷指令列表失败，可直接输入名称": "Could not read the shortcuts list; type the name instead",
        "快捷指令 App 里还没有快捷指令，可直接输入名称": "No shortcuts in the Shortcuts app yet; you can type a name",
        "想用手势开关勿扰：在快捷指令里建一个「设定专注模式」的快捷指令，再用这个动作运行它": "To toggle Do Not Disturb with a gesture: create a shortcut with the Set Focus action in Shortcuts, then run it with this action",
        "*图标已隐藏：在访达或启动台里再次打开 GestureKit 即可回到这里": "*Icon hidden: open GestureKit again from Finder or Launchpad to come back here",
        "重置「%@」的规则？": "Reset the “%@” rules?",
        "当前 %d 条将恢复为出厂的 %d 条（仅限「%@」，其它页面不变）。会先备份当前 rules.json。": "The current %d rule(s) will be replaced by the %d factory rule(s) (only for “%@”; other pages are unchanged). rules.json is backed up first.",
        "GestureKit %@": "GestureKit %@",
        "GestureKit 不联网，不会自动检查更新。新版本请重新编译安装（./build.sh --install）。": "GestureKit never goes online, so it doesn't check for updates. To update, rebuild and install (./build.sh --install).",
        "版本信息": "Version Info",
        "添加规则": "Add Rule",
        "删除所选规则": "Delete Selected Rule",
    ]
    // END-EN
}
