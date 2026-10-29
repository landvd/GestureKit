# 模块 12 · HUD 提示

## 职责
触发动作时在光标附近显示一行文字（备注/动作名），几秒后淡出。

## 窗口
```swift
let panel = NSPanel(contentRect: .zero,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: true)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.ignoresMouseEvents = true
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
```

## 内容
- 圆角 `NSVisualEffectView`（`.hudWindow`）+ `NSTextField`（白字、13pt）。
- 可选图标（动作类型图标）。
- 最大宽度 320pt，超出省略。

## 布局
```swift
let size = text.size(withAttributes: attrs)
let origin = CGPoint(x: point.x + 14, y: point.y + 14)   // CG 坐标
// 超出屏幕 → 翻转到左/上
let screen = NSScreen.screens.first { $0.frame.contains(nsPoint) } ?? .main
```
注意 CG(左上) ↔ NS(左下) 转换。

## 动画
```
show: alpha 0 → 1（0.12s），scale 0.96 → 1
hold: retentionTime（默认 1.2s，可配）
hide: alpha 1 → 0（0.25s），然后 orderOut
```
- 新消息到来时复用窗口，重置计时器（不叠加多个 HUD）。

## 配置项
| 键 | 含义 |
|---|---|
| `showActionOrNote` | 是否显示 |
| `actionOrNoteRetetionTime` | 停留秒数（默认 0.5） |
| `YLHudConfig` | 样式（圆角、阴影、深浅色、偏移） |

## 边界
- 全屏 App 上也能显示（`fullScreenAuxiliary`）。
- 多屏跟随光标所在屏。
- 不抢焦点（`nonactivatingPanel` + `ignoresMouseEvents`）。

## 测试点
- 连续触发两次 → 只有一个 HUD，文字更新
- 全屏 App 上可见
- 屏幕边缘自动翻转


## 实现（2026-10-28）
- `Sources/HUD.swift`：单个 `NSPanel` 复用；新消息取消旧的淡出并重置计时（generation 计数防竞态）。
- 位置：光标右下 16pt，超出可见区域翻转到左/上（`HUD.origin`，自检覆盖）。
- 文本：`ActionCatalog.hudText` — 备注优先；只含空格不提示；快捷键显示 label；其余显示动作中文名。
- 挂载点：`Actions.presenter`（AppDelegate 设置），`--dry-run` 下同样显示，`--selftest` 不创建窗口。
- 配置：`showHUD`（默认 true）、`hudDuration`（默认 0.5s）；设置「通用设置 → 提示备注或动作」开关已接通。
