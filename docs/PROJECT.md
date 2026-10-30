# GestureKit 架构说明

> 给接手写代码的人/AI 看。现状与剩余工作见 `STATUS.md`，硬性约束见根目录 `CLAUDE.md`。

## 1. 一句话

macOS 菜单栏鼠标手势工具：按住右键（或左右双键）画手势 → 识别 → 执行动作；
另有屏幕边角滚轮调音量/亮度。Swift + AppKit/SwiftUI，无第三方依赖，`swiftc Sources/*.swift` 即可编译。

## 2. 数据流

```
CGEventTap（TapThread 独立线程）
  └─ EventTap.dispatch → GestureEngine.handle      ← 状态只在这条线程读写
        ├─ 起手/拖动：吞事件、记轨迹（onChordStroke → 主线程画 GestureTrail）
        ├─ 松开：deferWork（后台队列）→ Recognizer.recognize(规则快照)
        │        → Actions.executor（Actions.workQueue）→ Actions.perform(ActionSpec)
        │        → GestureHistory（主线程，history.json）
        ├─ 右键单击未画：松开时补发右键（带 syntheticMarker；isOwnReplay 防循环）
        └─ 边角滚轮：累积 + 节流 0.4s → corner.<角>.<up|down> 规则
主线程：AppDelegate（菜单、配置、权限）、设置窗口、HUD、轨迹
```

## 3. 文件职责

| 文件 | 职责 |
|---|---|
| `main.swift` | 入口与命令行开关；通用自检断言 |
| `AppDelegate.swift` | 菜单栏、启动引擎、配置读写、开机自启、与 BetterAndBetter 冲突提醒 |
| `EventTap.swift` | `TapThread` + CGEventTap；回调里只做最快的判断 |
| `GestureEngine.swift` | 起手/吞放/轨迹/右键补发/边角滚轮的状态机 |
| `Recognizer.swift` | 纯函数：笔画 → 命中哪个手势（形状/方向/按键/反例/把握不足） |
| `Shape.swift` | DTW 形状匹配 + 内置字形模板 |
| `GestureHistory.swift` | 手势记录（200 条）、评价、正样本/反例学习 |
| `HistoryPage.swift` / `HistoryReplay.swift` | 记录页 UI；`--replay-history` 重放 |
| `Rules.swift` | `ActionSpec` / `Ruleset` / `Config` 与默认规则；音量步长 |
| `ConfigIO.swift` | 导入/导出/重置/每日自动备份 |
| `Actions.swift` | 执行动作；副作用经 `ActionEffects`（测试用记录实现） |
| `ActionCatalog.swift` | 预设动作清单与显示名 |
| `WindowLayout.swift` | 半屏/四分之一屏等布局计算 |
| `OutputVolume.swift` / `DisplayBrightness.swift` | CoreAudio 音量；内建屏 + 外接屏 DDC 亮度 |
| `HUD.swift` / `GestureTrail.swift` | 光标旁提示；手势轨迹 |
| `Preferences.swift` / `RuleEditor.swift` | 设置窗口；新增/编辑规则面板 |
| `PermissionWizard.swift` | 辅助功能权限向导 |
| `L10n*.swift` | 中文原文作 key 的英文表 |
| `Log.swift` | 文件日志（2MB 轮换；测试写临时文件） |
| `PerfBench.swift` / `TapIsolationTest.swift` / `PrefsClickTest.swift` | `--perf` / `--tap-isolation-test` / `--ui-click-test` |
| `SelfTest*.swift` | 各区域自检，在 `SelfTestSuites.swift` 注册 |

## 4. 配置（`~/Library/Application Support/GestureKit/rules.json`）

- `rulesets`：`"default"` + 按 bundle id 的 App 专属规则（专属优先，其余沿用 default）。
- 手势 id：`twoKey.<方向|折线|字形|key.x|custom.名字>`（右键与双键起手通用）、`corner.<角>.<up|down>`。
- 动作 `ActionSpec`：`type` + 参数，类型清单见 `Rules.swift` 顶部注释。
- 其他：`gestureButton`（right/chord）、`blacklist`、`showHUD`、`trail`、`language`、
  `learnedStrokes` / `rejectedStrokes`（个人学习数据）、`customGlyphs`。

## 5. 测试

`./build.sh` 跑全部自检；其余命令见 `STATUS.md` §3。新增手势或动作必须加断言。
