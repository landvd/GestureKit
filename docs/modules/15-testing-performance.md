# 模块 15 · 测试与性能

## 测试金字塔

| 层级 | 范围 | 手段 |
|---|---|---|
| 单元 | 识别算法、几何、归一化、匹配 | 纯函数 + 固定输入 |
| 集成 | 事件 → 识别 → 规则 → 动作 | 合成 CGEvent + 假 ActionRunner |
| 真机 | 各设备、各 App | 人工清单 |
| 回归 | 每个 bug | 合成事件用例固化 |

## 合成事件
```swift
func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) -> CGEvent {
    CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: p, mouseButton: button)!
}
// 直接喂给 Recognizer，不经过系统（无需权限，可 CI）
recognizer.consume(mouse(.leftMouseDown, p, .left))
```

## 测试矩阵（人工）

| 设备 | 用例 |
|---|---|
| 普通鼠标 | 左/右/中/4-8 键、滚轮四向、双键+方向、双键+字母、按住 |
| 妙控鼠标 | 单指/双指/三指、区域点按、模拟中键 |
| 触控板 | 1-5 指 Tap/Swipe/Pinch、边缘滑入、指尖轻点、绘图 |
| 键盘 | 组合键、修饰键维度 |
| 边角 | 四角 × 上下滚 |
| 系统 | 锁屏/睡眠/截图/音量/亮度 |

## 性能预算

| 指标 | 目标 |
|---|---|
| 事件回调 | < 200µs |
| 手势识别 | < 100µs |
| 动作执行 | 快捷键 < 5ms；AX < 50ms；AppleScript < 200ms |
| 内存 | < 80MB |
| 空闲 CPU | < 0.5% |
| HUD 显示延迟 | < 16ms |

## 监控
- 内置计数器：事件数/秒、识别耗时 P99、动作失败数。
- 日志分级：ERROR/WARN/INFO/DEBUG，文件按 5MB 轮转，保留 3 份。
- 诊断导出：打包 config + 最近日志 + 系统版本 + 设备信息（脱敏）。

## 稳定性清单
- [ ] tap 超时自动恢复
- [ ] 无权限不崩溃
- [ ] 配置损坏可恢复
- [ ] 睡眠唤醒后功能正常
- [ ] 高负载（1000 事件/秒）不丢动作
- [ ] 与同类软件并存有提示

## 实现（2026-10-28）· P2-17 动作层单测

### 副作用接缝
- `Sources/Actions.swift` 新增协议 `ActionEffects`，`Actions` 持有实例属性 `var effects: ActionEffects`
  （默认 `SystemActionEffects()`，即原来的真实行为）。`Actions` 只负责决定「做什么」——构造并打
  `syntheticMarker` 的 CGEvent、拼 AppleScript 源码、算路径和参数；真正「去做」全部经过 effects：
  - 事件：`post(CGEvent)`（快捷键、鼠标、滚动、NX 系统键）
  - AX：`axCopy` / `axSet` / `axPerform`
  - 进程与脚本：`run(path, args, wait:)`（返回 stdout）、`runAppleScript`、`runScript`（ScriptRunner）、`open(URL)`
  - 系统服务：`coreDockNotify`、`lockScreen`、`bluetoothPower`/`setBluetoothPower`、`selectInputSource`、
    `adjustBrightness`（DisplayBrightness 入口）、`emptyTrash`
  - App 级：`postNotification`、`terminateSelf`、`after(秒, block)`（延迟发送）、`log`（Log.write）
  - 决定行为的读取：`frontmostApplication`、`frontmostBundleID`、`runningApplications`
- `dryRun` / `observer` / `presenter` / `syntheticMarker` / HUD 语义不变；dryRun 仍在任何 effect 之前返回。
- 唯一的可见差异：未知 `snap` op 和未知动作 `type` 现在会写一行 `unknown …` 日志（以前静默）。

### 测试（`Sources/SelfTest+Actions.swift`）
- `RecordingActionEffects` 只记录调用、不碰系统；读取一律返回「没有前台 App / 没有窗口 / 没有运行中的 App」，
  `after` 立即执行（延迟任务不会逃出测试）。每条用例新建 `Actions()` + 新 recorder，不碰 `Actions.shared`。
- 关掉 dryRun 跑真实 `perform`，结束后 `defer` 还原 dryRun / observer / presenter。
- 覆盖：shortcut keyCode+flags+down/up+标记；volume AppleScript；brightness 入口参数；script 转发；
  newTab ⌘T、emojiPicker ⌃⌘Space、missionControl CoreDock、键盘背光 16×21 / 中档、playPause；
  finderTrashSelected 在 Finder 不在/在前台；goToFolder 延迟 0.25s 后 ⇧⌘G；openDownloads 路径；
  leftClick down+up、scrollLeft 像素；截图参数；toggleDock 读→写→killall；蓝牙取反；
  openAppPreferences 通知；quitGestureKit；fullscreen 无窗口回退 ⌃⌘F。
- **`ActionCatalog.choices` 每一项都被 perform 识别**（不出现 `unknown …` 日志），且每个 system op 都产生效果
  （无 App 时天然为空的 6 个除外）；systemGroups 与 systemNames 一一对应。
- 未知 system / window / snap op 与未知 type 只记日志、不崩溃、无效果；dryRun 下无任何效果。

### 未覆盖
- 有真实窗口时的 AX 读写（窗口最小化/布局/跨屏）：recorder 不伪造 AXUIElement，几何部分由 WindowLayout 纯函数测试负责。
- hide/unhide/activate 其它 App（recorder 不提供 NSRunningApplication）。


## 实现（2026-10-28）：普通鼠标手势流畅度

### 工具
- `GestureKit --perf`（`Sources/PerfBench.swift`，约 7 秒，固定随机种子，未达预算时退出码 1）：
  - **P1** tap 回调里每个事件的耗时：mouseMoved / 普通拖动 / 组合手势拖动（5000 点）/ 滚轮（含真实前台 App 查询）。预算 p99 < 50µs。
  - **P2** 松手识别 + 派发耗时，按笔画长度（30/200/1000 点）与规则数（默认 / +24 个字形）。预算 max < 8ms。
  - **P3** 识别稳定性：24 个内置字形 × 40 次，随机大小 / 宽高比 / 旋转 / 抖动 / 采样速度，分「仔细 / 正常 / 潦草」三档，
    报告命中率、最差字形、常见混淆；另测 < 30pt 小笔画不得触发字母。
  - **P4** 轨迹：点转换与 2000 点路径离屏绘制。
  - **P5** 动作执行对 tap 的占用（模拟 100ms 慢动作）、CoreAudio / AppleScript / AX / NSWorkspace 的单次开销。
- `GK_PERF=1 /Applications/GestureKit.app/Contents/MacOS/GestureKit`：真实事件管线探针，每 10 秒在日志写
  `perf tap: moved n=… p50=… p99=… max=… >1ms=…`（按事件类型），即 GestureKit 给系统鼠标输入增加的延迟。
- `--selftest` 里的 `perf:` 5 条是精简版回归断言（约 1 秒，预算放宽，识别率确定性）。

### 首次测量发现并修复（2026-10-28）
| 问题 | 影响 | 修复 | 结果 |
|---|---|---|---|
| 动作在 tap 回调里同步执行（AppleScript 音量首次 ~126ms；AX 调用卡住的 App 时无上限） | tap 监听鼠标移动后，执行动作期间全系统鼠标事件被阻塞 | `Actions.executor` → 后台 `Actions.workQueue`；需要 AppKit 的部分 `onMain`；AX 消息超时 0.5s | 100ms 慢动作期间 tap 只被占用 ≤ 0.18ms |
| 音量用进程内 NSAppleScript | 慢、且不能离开主线程 | CoreAudio `VirtualMainVolume`（`OutputVolume.swift`），不支持的设备回退异步 `osascript` | — |
| 边角滚轮被节流吞掉的事件仍在累加 | 快速反向滚动（调回音量）会按原方向再触发一次 | 方向反转时清零累加 | 实测 38→38 |
| 每个滚轮事件都 `NSScreen.screens` 计算边角 | 真实管线滚轮 p50 166µs | 屏幕布局缓存（屏幕变化通知时刷新）+ 前台 App 缓存 | 滚轮 p50 4µs、max 235µs、>1ms 0 次 |
| `Log.write` 每行新建 ISO8601DateFormatter、同步写 stderr | 触发动作的那个事件变慢 | 格式化与写入都放到日志队列，文件句柄常开 | — |
| 首个鼠标事件 14.5ms（AppKit 屏幕初始化） | 启动后第一次移动鼠标卡一下 | 启动时 `engine.warmUp()` | 11µs |

### 当前基线（M1 Pro，macOS 27）
- tap 回调：移动 p50 1µs / p99 4µs；滚轮 p50 4µs；组合手势拖动 p99 0.1µs（离线）。
- 松手识别：默认规则 ~0.6ms，34 条字形规则 ~1.8ms。
- 识别率：仔细 100%、正常 99.9%、潦草 95.6%；主要混淆 `<`↔`C`、潦草的 `F`→`↗`、`H`→`↘`。
