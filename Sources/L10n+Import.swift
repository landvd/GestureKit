import Foundation

// Import 区域的英文表。格式同 L10n.swift：一行一条 `"中文原文": "English",`，
// 放在 BEGIN-EN / END-EN 之间（scripts/check-l10n.sh 依赖）。
extension L10n {
    // BEGIN-EN
    static let enImport: [String: String] = [
        "GestureKit 暂无字形「%@」": "GestureKit has no built-in glyph “%@”",
        "GestureKit 暂无对应的预设动作": "No matching preset action in GestureKit",
        "……另有 %d 条": "…and %d more",
        "不是有效的 BetterAndBetter 预设文件（不是归档）": "Not a valid BetterAndBetter preset (not a keyed archive)",
        "不是有效的 BetterAndBetter 预设文件（无法读取）": "Not a valid BetterAndBetter preset (unreadable)",
        "不是有效的 BetterAndBetter 预设文件（根对象不是字典）": "Not a valid BetterAndBetter preset (root is not a dictionary)",
        "不是有效的 BetterAndBetter 预设文件（没有规则分组）": "Not a valid BetterAndBetter preset (no rule groups)",
        "与同一 App 里的另一条规则对应到同一个手势": "Maps to the same gesture as another rule for this app",
        "原版脚本库（%d 个）不会导入。": "The original script library (%d) is not imported.",
        "可导入 %d 条规则，跳过 %d 条。": "%d rules can be imported, %d skipped.",
        "合并：保留现有规则，同一手势以预设为准。\n覆盖：用预设替换全部规则（设置保持不变）。\n导入前会自动备份当前 rules.json。": "Merge: keep existing rules; the preset wins on the same gesture.\nReplace: replace all rules with the preset (settings are kept).\nThe current rules.json is backed up first.",
        "导入 BetterAndBetter 预设": "Import BetterAndBetter Preset",
        "导入支持 GestureKit 规则（.json）和 BetterAndBetter 预设（.BABPreset）。导入前会显示可导入与跳过的规则，并自动备份当前规则；保存设置时每天自动备份一次，保留最近 5 份。": "Import accepts GestureKit rules (.json) and BetterAndBetter presets (.BABPreset). You will see which rules can be imported or are skipped, and current rules are backed up first. Settings are also backed up automatically once a day when saved (last 5 kept).",
        "快捷键缺少按键": "Shortcut has no key",
        "无法读取文件。": "Could not read the file.",
        "暂不支持这类动作（%@）": "Action type not supported yet (%@)",
        "暂不支持这类手势": "Gesture not supported yet",
        "暂不支持这类边角手势": "Corner gesture not supported yet",
        "暂只支持双键手势（原为 %d 键）": "Only two-button gestures are supported (this one uses %d)",
        "空规则（没有设置动作）": "Empty rule (no action)",
        "空规则（没有设置手势）": "Empty rule (no gesture)",
        "自定义笔画无法读取": "Custom stroke could not be read",
        "跳过的规则：": "Skipped rules:",
        "预设里没有可导入的规则": "No importable rules in this preset",
        "GestureKit 不支持%@规则": "GestureKit does not support %@ rules",
    ]
    // END-EN
}
