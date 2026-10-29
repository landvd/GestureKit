# 模块 10 · 输入类动作（快捷键/文本/脚本/打开/菜单）

## 快捷键
```swift
func send(keyCode: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .combinedSessionState)
    guard let d = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
          let u = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
    d.flags = flags; u.flags = flags
    d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
}
```
- 修饰键：⌘ 0x100000、⌥ 0x80000、⌃ 0x40000、⇧ 0x20000（可或）。
- Fn 键需要 `.maskSecondaryFn`。
- 某些组合是系统保留键（⌘⇥ 等）→ 录制时就应拒绝并提示。

## 文本输入
```swift
func type(_ text: String) {
    for chunk in text.chunked(max: 20) {          // 单次太长会被截断
        let utf16 = Array(chunk.utf16)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        utf16.withUnsafeBufferPointer {
            e.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: $0.baseAddress!)
        }
        e.post(tap: .cghidEventTap)
    }
}
```
- 不要用 keyCode 模拟字母（受键盘布局影响）。
- 中文/emoji 走 unicode string。

## AppleScript
```swift
let script = NSAppleScript(source: src)!
var err: NSDictionary?
let out = script.executeAndReturnError(&err)
if let err { Log.write("script error: \\(err)") }
```
- 脚本库：`~/Library/Application Support/<App>/Scripts/*.scpt`，用
  `NSAppleScript(contentsOf:error:)` 加载。
- 需要控制其它 App 时，首次会弹"自动化"授权（Info.plist 加
  `NSAppleEventsUsageDescription`）。
- 超时保护：AppleScript 可能挂起 → 放到后台队列 + 超时放弃（不能强杀，只能忽略结果）。

## 打开目标
```swift
NSWorkspace.shared.open(url)                                  // 文件/文件夹/URL
NSWorkspace.shared.openApplication(at: appURL, configuration: .init())  // App
```
- 支持拖入 App/文件/文件夹/URL（`OpenPopoverView`）。
- 路径不存在 → 提示并标记规则失效。

## 菜单点击（ClickMenuTitle）
```swift
// 路径形如 "/Apple/关机"、"/窗口/缩放"
// 1) 取前台 App 的 AXMenuBar
// 2) 逐级 AXChildren 匹配 AXTitle
// 3) 命中后 AXUIElementPerformAction(item, kAXPressAction)
```
- 标题必须精确；`APPLE` 写作 `Apple`（原版提示）。
- 菜单未展开时也能点（AX 可以），但某些 App 需要先 AXPress 父级。

## 模拟触控板手势
| 手势 | 实现 |
|---|---|
| Free Scroll | 定时器按帧 post `scrollWheel`（带 phase/momentum） |
| Zoom/Rotate | post `magnify`/`rotate` 事件（`NSEvent` → `cgEvent`，或私有 gesture 字段） |

## 测试点
- ⌘[ / ⌘] / ⌃⌘F 在 Safari 生效
- 中文文本输入正确
- AppleScript 出错不影响主流程
- 打开不存在的路径有提示
- 菜单路径匹配成功/失败各一条


## 实现（2026-10-28）：脚本
- `Sources/ScriptRunner.swift`，动作 `{"type":"script","script":<文件名>,"handler":<可选>,"args":[...]}`。
- 目录：`~/Library/Application Scripts/local.gesturekit.GestureKit/`；名称不能含 `/` 或 `..`；
  无扩展名时按原版补 `.scpt`。
- `.scpt/.scptd/.applescript` → `NSUserAppleScriptTask`（进程外执行，挂起的脚本不会卡住事件 tap）。
  有 handler → 子程序事件（handler 名小写发送）；无 handler → `aevt/oapp`，`on run argv` 收到参数列表。
- 其它文件（需可执行位）→ `NSUserUnixTask`，参数作为 argv，stdout 记日志。
- 结果/错误写日志；脚本库页「运行」显示最近一次结果。删除 = 移到废纸篓，并提示仍在使用它的规则数。
- 控制其它 App 的脚本首次运行会触发系统「自动化」授权弹窗（Info.plist 已有 `NSAppleEventsUsageDescription`）。


## 实现（2026-10-28）：新动作类型
参数都是 `ActionSpec` 的新可选字段（老配置不含这些键，照常解码；nil 字段不写进 JSON）。
副作用全部经 `ActionEffects`（新增 `applicationURL(bundleID:)` / `openApplication(_:)` /
`fileExists(_:)` / `cursorLocation`），自检用 `RecordingActionEffects` 记录，见 `SelfTest+ActionsExt.swift`。

| type | 字段 | 实现 |
|---|---|---|
| `openApp` | `bundleID`、`path` | bundleID → LaunchServices 找到就 `NSWorkspace.openApplication`（activates，已运行即切换）；找不到 → `path` 存在则打开它；再不行 → 激活同 bundleID 的运行中 App；都没有只记日志 |
| `openURL` | `url` | `Actions.resolveURL`：`/`、`~` 开头 → 文件 URL（不存在只记日志）；`scheme:…` 原样；`example.com`、`localhost:3000` 补 `https://`；空/含空格的非 URL → nil（编辑器不能保存） |
| `typeText` | `text` | 按字符（不拆代理对）分块，每块 ≤20 个 UTF-16 单元，`keyboardSetUnicodeString` 的 keyDown+keyUp，flags 清零，打 `syntheticMarker`；换行 → 回车键（36）。日志只写长度，perform 的 action 行 label 也换成 `<n chars>` |
| `runShortcut` | `shortcutName` | `effects.run("/usr/bin/shortcuts", ["run", name], wait: false)`，不阻塞主线程 |
| `window` op `moveToNextSpace` / `moveToPrevSpace`（实验） | — | 取前台窗口 AX 框和缩放（或最小化）按钮框，抓取点 = 按钮右侧 8pt、按钮垂直中线；点必须在窗口内、距顶 < 40pt，否则跳过。左键按下 + 原地拖动 → 0.05s 后 ⌃→/⌃← → 0.35s 后松开并把光标移回。依赖系统「移到左/右侧空间」快捷键开启；无公开 API，部分 macOS 版本可能无效 |

编辑器（`RuleEditor.swift`）：动作菜单顶部新增「打开 App…」「打开网址或文件…」「输入文字…」「运行快捷指令…」。
App 列表 = `/Applications`(+Utilities)、`/System/Applications`(+Utilities) 下的 .app + 运行中的 App（后台线程扫描），
也可「选择…」用 NSOpenPanel；快捷指令列表后台跑 `shortcuts list`（10s 超时），失败/为空时仍可手输名称，
并提示用「设定专注模式」快捷指令替代勿扰开关。
