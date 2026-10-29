# 模块 08 · 窗口动作（Accessibility）

## 职责
最小化/恢复/全屏/最大化/半屏/跨屏/自定义位置，全部基于 `AXUIElement`。

## 基础封装
```swift
func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
func axSet(_ el: AXUIElement, _ attr: String, _ v: CFTypeRef) {
    AXUIElementSetAttributeValue(el, attr as CFString, v)
}
func focusedWindow(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    guard let v = axCopy(app, kAXFocusedWindowAttribute as String) else { return nil }
    return unsafeBitCast(v, to: AXUIElement.self)
}
```

## 几何
```swift
func setFrame(_ win: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    axSet(win, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &p)!)
    axSet(win, kAXSizeAttribute as String,     AXValueCreate(.cgSize, &s)!)
}
```
坐标系：AX 与 CGEvent 都是**左上原点**；`NSScreen.frame` 是左下 →
`cgY = mainHeight - nsY - height`。

## 各动作实现

| 动作 | 实现 |
|---|---|
| 最小化 | `kAXMinimized = true` |
| 恢复最小化 | 遍历该 App 窗口找 `minimized == true` → false + `AXRaise` |
| 全部最小化 | 遍历 `NSWorkspace.runningApplications`（regular）所有窗口 |
| 全部恢复 | 同上，把 minimized 置 false |
| 全屏 | `AXFullScreen` 取反；失败回退 ⌃⌘F |
| 最大化 | 设为屏幕 `visibleFrame` |
| 半屏 | 用 `visibleFrame` 的 1/2（左/右/上/下）；四角用 1/2×1/2 |
| 宽度最大化 | 保持 y/h，x=vf.minX，w=vf.width |
| 高度最大化 | 保持 x/w，y=vf.minY，h=vf.height |
| 移到下一屏 | 计算 `NSScreen.screens` 中下一个屏的 visibleFrame，等比移动 |
| 移到下一 Space | 无公开 API → 合成 ⌃→（`NSEvent`/`CGEvent`） |
| 自定义 | 用户输入 x/y/w/h（`UserDefinedWindow`） |
| 恢复原位置 | 执行前记录 frame 到栈，恢复时弹出 |

## 多屏与可见区域
```swift
func visibleFrame(for win: AXUIElement) -> CGRect {
    // 取窗口中心点落在哪个屏幕
    guard let f = currentFrame(win) else { return NSScreen.main!.visibleFrame }
    let center = CGPoint(x: f.midX, y: f.midY)
    let screen = NSScreen.screens.first { $0.frame.contains(cgToNS(center)) } ?? NSScreen.main!
    return screen.visibleFrame
}
```
`visibleFrame` 已排除菜单栏与 Dock，直接用它算半屏。

## 失败与回退
- 目标 App 不支持 AX（少数 Electron/游戏）→ 记录日志，回退快捷键方案。
- 窗口被系统固定（如某些面板）→ 设置失败不崩溃。
- 全屏时 `AXFullScreen` 可能异步生效 → 不要立刻读回校验。

## 性能
- 批量（全部最小化）时逐 App 操作，单次 < 5ms；App 多时后台队列。
- 避免在事件回调里同步做批量 AX。

## 测试点
- Safari/Finder/VS Code 三个 App 的半屏/最大化/全屏
- 双屏时窗口跨屏移动
- 全屏后退出全屏
- 最小化后恢复，焦点回到原窗口


## 实现（2026-10-28）
- 所有窗口动作统一在 Cocoa 坐标里算：`cocoaFrame` = AX 位置 → `WindowLayout.fromAX`，写回时 `toAX`；
  所在屏 = 与窗口相交面积最大的屏。
- `WindowLayout.frame(for:in:current:)`：居中（保持尺寸、整数居中）、最大化宽度（保持高度与 y）、
  最大化高度（保持宽度与 x），超出屏幕时夹紧。
- `window` 新 op：`enterFullScreen` / `exitFullScreen`（AXFullScreen，失败回退 ⌃⌘F）、`zoom`（按标题栏缩放按钮）、
  `smartZoom`（已最大化 → 还原，否则最大化）、`restorePrevious`（每次布局/跨屏前记下原位置，最多 30 个窗口）。


## 实现（2026-10-28）：窗口吸附
- `Sources/WindowDock.swift`。`GestureEngine` 在所有判断之前把 mouseMoved / leftMouseDown / leftMouseUp
  转给它（只观察、从不吞事件；暂停状态下也工作，保证藏起来的窗口总能找回来）。EventTap 掩码新增 mouseMoved。
- 吸附：窗口 x 移到 `屏幕左缘 − 宽 + 1` 或 `屏幕右缘 − 1`，留 1px；宽或高 < 50 不吸附；
  移动后读回位置，App 不肯离屏（被夹回）就放弃跟踪。
- 滑回：光标在该屏外缘 2pt 内且纵向落在窗口范围 → 滑回 + 激活 + AXRaise；光标离开窗口 30pt 外再藏回。
- 取消：拖动已吸附的窗口位移 ≥ 20pt。多屏时两屏相接的边不算边缘。
- 自动吸附（`windowDock: true`）：按下时记下光标下的窗口和位置，松开时在外缘且窗口被拖动过 → 吸附。
- 动画：8 步约 0.15s ease-out，只改位置。退出 App、关闭开关时 `revealAll()`。
- AX 调用都在事件回调返回后异步执行。
