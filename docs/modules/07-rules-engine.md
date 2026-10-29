# 模块 07 · 规则引擎

## 职责
`(bundleID, gestureID, modifier)` → `ActionSpec`；处理优先级、黑名单、启用位、
光标下生效。

## 数据模型
```swift
struct ActionSpec: Codable {
    var type: String            // shortcut | preset | script | open | text | menu | simulate
    var keyCode: Int?
    var modifiers: UInt32?
    var label: String?
    var op: String?             // preset: minimize/halfLeft/...
    var target: String?         // open: 路径/URL；text: 文本；script: 源码
    var enabled: Bool = true
}

struct Rule: Codable {
    var gesture: String         // "rightOf2Key" / "2Finger_Swipe_Left" / "corner.topRight.up"
    var modifier: String        // "-" / "⌘⌥" ...
    var action: ActionSpec
    var note: String?
    var enabled: Bool
    var underCursor: Bool
}

struct Ruleset: Codable { var app: String; var rules: [Rule] }

struct Config: Codable {
    var version: Int
    var rulesets: [String: [Rule]]     // key = bundleID 或 "default"
    var blacklist: [String]
    var buttonBlacklist: [String: [Int]]  // bundleID -> [button]
}
```

## 匹配顺序
```
1. 黑名单：bundleID ∈ blacklist → 直接 return nil（整体挂起）
2. 按键黑名单：button ∈ buttonBlacklist[bundleID] → 只对该键 return nil
3. 专属规则：rulesets[bundleID] 精确匹配 (gesture, modifier)
4. 全局规则：rulesets["default"] 匹配
5. 都没有 → nil
```

## 修饰键归一化
```swift
func modifierString(_ flags: CGEventFlags) -> String {
    var s = ""
    if flags.contains(.maskControl)   { s += "⌃" }
    if flags.contains(.maskAlternate) { s += "⌥" }
    if flags.contains(.maskShift)     { s += "⇧" }
    if flags.contains(.maskCommand)   { s += "⌘" }
    return s.isEmpty ? "-" : s
}
```
顺序固定，避免 `⌘⌥` 与 `⌥⌘` 匹配不上。

## EnableUnderCursor
```swift
// 执行"窗口类"动作前：把光标下的窗口所属 App 激活
let sys = AXUIElementCreateSystemWide()
var el: AXUIElement?
AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el)
// 从 el 向上找 AXWindow → 取 pid → NSRunningApplication.activate
```
只对窗口/菜单类动作有意义；对快捷键类动作会改变目标 App，需谨慎（默认关）。

## 备注与 HUD
- `note` 非空且非纯空格 → HUD 显示备注；否则显示动作名。
- 空备注（或纯空格）不提示。

## 版本迁移
- `version` 递增；读取时若小于当前版本，跑迁移函数：
  `1→2: 老字段 xxx 改名 yyy`。迁移后再写回。

## 边界
- `frontmostApplication == nil`（无 GUI/锁屏）→ 只用 default 规则。
- App 名 vs bundleID：配置统一存 bundleID；导入老配置时按名称反查。
- 同一手势多条规则：先按 modifier 精确匹配，再回退到 `-`。
- 规则 id 大小写敏感，导入时统一小写。

## 测试点
- 专属规则覆盖全局
- 黑名单命中 → 不触发
- 按钮黑名单只屏蔽指定键
- modifier 顺序不同仍匹配
- 空配置不崩溃
