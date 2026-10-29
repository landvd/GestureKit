# 功能对照与实现建议（Parity）

> 数据来源：用户机器上的 BetterAndBetter 配置快照
> `~/Library/Preferences/4K6FWZU8C4.cn.better365.BetterAndBetter.plist`
> 与 `~/Desktop/2026-10-28-01-45-43.BABPreset`（NSKeyedArchiver）。

---

## 1. 用户实际在用的配置（原始）

### 1.1 普通鼠标 · 全 App（9 条，全部启用）

| 原手势 id | 备注 | 原动作 | GestureKit 规则 |
|---|---|---|---|
| ` ←Of2Key` | 前进 | ⌘] | `twoKey.left` → keyCode 30 |
| ` →Of2Key` | 后退 | ⌘[ | `twoKey.right` → keyCode 33 |
| ` ↘Of2Key` | 窗口最小化 | Preset `Minimization` | `twoKey.downRight` → `window/minimize` |
| ` ↖Of2Key` | 恢复最小化窗口 | Preset `Minimization Recovery` | `twoKey.upLeft` → `window/restore` |
| ` AOf2Key` | — | Preset `All Minimization` | `twoKey.key.a` → `window/minimizeAll` |
| ` VOf2Key` | — | Preset `Minimization All Recovery` | `twoKey.key.v` → `window/restoreAll` |
| ` ↗Of2Key` | 窗口全屏 | Preset `Window Enter/Exit Full Screen` | `twoKey.upRight` → `window/fullscreen` |
| ` ↙Of2Key` | 退出全屏 | ⌃⌘F | `twoKey.downLeft` → keyCode 3 + ⌃⌘ |
| `!<Of2Key` | 退出当前 App | ⌘Q | `twoKey.key.<` → `quitApp` |

### 1.2 Safari（5 条）与 ego lite（5 条，配置相同）

| 原手势 | 原动作 | GestureKit |
|---|---|---|
| `!TOf2Key` | `Open a New Tab` | `twoKey.key.t` → ⌘T |
| `!FOf2Key` | `Close the Tab` | `twoKey.key.f` → ⌘W |
| ` ←Of2Key` | `Page Back` | `twoKey.left` → ⌘[ |
| ` →Of2Key` | `Page Forward` | `twoKey.right` → ⌘] |
| `CustomizeOf2Key` | ⌘R | `twoKey.key.r` → ⌘R |

> 注意：全 App 的 ← 是 ⌘]（前进），Safari 的 ← 是 ⌘[（后退），原配置本身方向相反。
> GestureKit 按原样保留，用户想统一改 JSON 即可。

### 1.3 触控板（Safari 2 条）

| 原手势 | 原动作 | GestureKit |
|---|---|---|
| `2Finger_Swipe_Left` | `Page Back` | `trackpad.swipeLeft` → ⌘[ |
| `2Finger_Swipe_Right` | `Page Forward` | `trackpad.swipeRight` → ⌘] |

### 1.4 热区 + 滚轮（6 条，启用 4 条）

| 原手势 | 原动作 | GestureKit |
|---|---|---|
| `Scroll Up at TopRight Corner` | `VolumeDown` | `corner.topRight.up` → volume −6 |
| `Scroll Down at TopRight Corner` | `VolumeUp` | `corner.topRight.down` → volume +6 |
| `Scroll Up at BottomLeft Corner` | `External Screen BrightnessDown` | `corner.bottomLeft.up` → brightness −0.0625（`op: external`，DDC/CI） |
| `Scroll Down at BottomLeft Corner` | `External Screen BrightnessUp` | `corner.bottomLeft.down` → +0.0625 |
| `BottomRight` up/down | 音量 ± | 原配置为**禁用**，GestureKit 未配 |

### 1.5 键盘规则（11 条，全部 `Enable=0`）

`⌥←/→/↑/↓` → 半屏（`half_of_Left/Right/Top/Bottom`）、`⌃⌘P/Q/R` →
偏好设置/退出/重启、`⌃⌘Z` → Zoom、`⌃⌘O` → 打开官网等，**均未启用**，未迁移。

### 1.6 AppleScript 动作（15 条）

`ruleOfAppleScript` 里 15 个条目全部 `AppName=None`、无规则（未使用）。

---

## 2. 原 App 的功能面（从配置与二进制观察到的）

`ActionType` 至少两种：`Shortcut Keys`（keyCode + modifierFlags + 展示名）
和 `Preset`（内置动作名）。配置里出现过的 Preset：

```
Minimization / Minimization Recovery / All Minimization / Minimization All Recovery
Window Enter/Exit Full Screen
Open a New Tab / Close the Tab / Page Back / Page Forward
Half_of_Top / Half_of_Right / Half_of_Bottom / half_of_Left
VolumeDown / VolumeUp / External Screen BrightnessDown / External Screen BrightnessUp
BetterAndBetter Preferences / Exit BetterAndBetter / Restart BetterAndBetter
Zoom / Open... / LockScreen / BrightnessUp / BrightnessDown
```

手势 id 家族（推断）：

```
<方向>Of2Key         双键 + 拖动（8 方向）
!<字母>Of2Key        双键 + 字母（T/F/< 已确认）
CustomizeOf2Key      双键 + 自定义
2Finger_Swipe_Left   触控板双指横扫
Scroll Up/Down at <Corner> Corner   热区滚动
```

> `!` 前缀和 `Customize` 的确切语义未能从二进制确认；GestureKit 统一按
> "双键 + 字母" 实现，行为一致即可。

---

## 3. 未实现清单（按优先级）

### P1-a 窗口贴边 / 半屏 / 移动

原 App 的 `Half_of_*`。用 Accessibility：

```swift
// 取前台窗口
let win = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &v)
// 读屏幕可用区域（排除菜单栏/Dock）
let vf = NSScreen.main!.visibleFrame
// 写位置/大小
AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString,
                             AXValueCreate(.cgPoint, &point)!)
AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString,
                             AXValueCreate(.cgSize, &size)!)
```

注意：CG 坐标 top-left，`NSScreen` bottom-left，需要 `mainHeight - y - h` 转换。
8 个方位建议做成 `window` 动作的 `op` + 参数：`{"op":"snap","value":"left"}`。

### P1-b 其它动作类型

| 动作 | 实现要点 |
|---|---|
| 打开 App | `NSWorkspace.openApplication(at:configuration:)` |
| 打开文件/URL | `NSWorkspace.open(_:)` |
| 运行 shell | `Process` + `/bin/zsh -lc`，需超时与输出上限，日志脱敏 |
| AppleScript | `NSAppleScript(source:)`，错误回传日志 |
| 模拟按键序列 | 复用 `sendShortcut`，支持 `delayMs` 与文本输入 `CGEvent.keyboardSetUnicodeString` |
| 媒体键 | `NX_KEYTYPE_PLAY` 等，`CGEvent` + `NSEvent.otherEvent(.systemDefined)` |
| 外接屏亮度 | DDC/CI（IOAVService）或 `DisplayServices` 遍历 `CGGetActiveDisplayList` |
| 锁屏 | `SACLockScreenImmediate`（需 dlsym）或 `CGSession -suspend` |

### P1-c 触控板手势增强

当前只用 `NSEvent.swipe`。更通用的方案：

```swift
// 在 CGEventTap 里看 scrollWheel 的 phase
let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
let mom   = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
// phase == 1 (began) 时记起点，4 (ended) 时按累计 dx 判方向
```

这样可以覆盖三指/四指横扫、捏合（`magnification` 需要 NSEvent monitor）。

### P2 配置界面

SwiftUI + `Settings` scene，或一个独立窗口；保存后调用
`engine.config = Config.loadOrCreate()` 即可热生效。

---

## 3.5 逆向覆盖度（2026-10-28 更新）

| 模块 | 逆向状态 | 文档 |
|---|---|---|
| 图形手势（DTW/阈值/字形） | ✅ 完整 | `ALGORITHMS_RECOVERED.md` |
| 触控板 1–5 指 | ✅ 阈值表 + 决策树 | `RE_MODULES.md` §1 |
| 按住/点击时序 | ✅ 1s / 50ms | §2 |
| 热区几何 | ✅ 1pt + 证伪 smallCorner | §3 |
| 平滑滚轮 | ✅ | §5 |
| 窗口预设（128 动作） | ✅ 全表 + 整数几何 | §6 |
| 窗口吸附 | ✅ 1px 留边 | §7 |
| 采集层 | ✅ HID 驱动 | §9 |
| HUD | ✅ 260pt/延迟换算 | §10 |
| 脚本库 | ✅ NSUserAppleScriptTask | §11 |
| iCloud | ✅ CloudKit profile_v2 | §12 |

## 3.6 实现状态（GestureKit）

| 功能 | 状态 | 备注 |
|---|---|---|
| 双键形状/方向/字母手势 | ✅ | DTW 85 分 |
| 折线手势 上左 ↑← / 上右 ↑→ / 下左 ↓← / 下右 ↓→ | ✅ 2026-10-29 | 新增，非原版功能；每个折线 3 个模板（等长/先长后短/先短后长）；与字母 F（=↑→）、L（=↓→）同形时折线优先 |
| 学习教程 / 免费 Apps / 问题反馈页 | ❌ 已移除 2026-10-29 | |
| 上下手势 ↑↓（默认刷新 ⌘R） | ✅ 2026-10-29 | 新增；与 ↑、↓、字母 A 区分（自检覆盖）；普通笔画识别率 97% |
| 普通鼠标页「添加应用程序…」 | ✅ 2026-10-29 | 任选 .app 新建专属规则组；未设置的手势沿用全局 |
| 右键手势（按住右键画；单击右键补发，菜单照常） | ✅ | 新增，非原版功能；「通用设置 → 鼠标手势」切换，与双键共用规则 |
| App 专属规则 + 全局规则合并（App 专属 > 全局，未定义的手势沿用全局） | ✅ | 之前是整套替换，已修 |
| 键盘手势 | ❌ 已移除 2026-10-29 | 精简：只保留鼠标手势 + 边角；导入时列入跳过 |
| 边角滚轮 | ✅ | |
| 触控板手势（双指翻页、1–5 指轻点/滑动/捏合/点按、Force Click 等） | ❌ 已移除 2026-10-29 | 导入时列入跳过；按键识别页仍能识别触控板设备（只用于排序） |
| 原版 .BABPreset 导入 | ✅ 2026-10-28 | 用户预设实测可导入 35 条、跳过 3 条；脚本库不导入 |
| 打开 App / 网址或文件 / 输入文字 / 运行快捷指令 | ✅ 2026-10-28 | 勿扰模式用「运行快捷指令」代替 |
| 移到上/下一个桌面空间 | ⚠️ 实验 2026-10-28 | 标题栏拖动 + ⌃←/⌃→，依赖系统快捷键，未验证 |
| 妙控鼠标手势 | ❌ 已移除 2026-10-29 | 启动时忽略妙控鼠标设备；导入时列入跳过 |
| 手势轨迹（显示/颜色/宽度） | ✅ 2026-10-28 | 双键手势时绘制，松手淡出 |
| 开机自启动 / 菜单栏图标开关 | ✅ 2026-10-28 | 隐藏图标后再次打开 App 进入设置 |
| HUD 提示 | ✅ 2026-10-28 | 260pt 最大宽，默认 0.5s |
| 平滑滚轮 / 滚轮方向反转 | ❌ 已移除 2026-10-29 | 滚轮事件原样放行（边角滚轮除外） |
| 规则添加/编辑/删除/启用/备注 | ✅ 2026-10-28 | 设置窗口即时生效 |
| 自定义绘图手势 | ✅ 2026-10-28 | 画板录制；不含原版 `!` 反向字形 |
| 规则导入/导出/重置 | ✅ 2026-10-28 | GestureKit JSON；不支持导入原版 .BABPreset |
| 脚本库 + 脚本动作 | ❌ 已移除 2026-10-29 | |
| 外接屏亮度 | ✅ 2026-10-28 | DDC/CI（Apple Silicon）；多屏按端口+EDID 映射，失败回退调全部；未接屏实测 |
| 预设动作 | ✅ 2026-10-28 | 115 个可选。未做：移到上/下一个桌面空间（无公开 API）、勿扰模式 4 个（macOS 12+ 无 API）、合盖不睡眠 2 个（需 root）、输入密码（安全原因不做）、滚动截图、`A`（语义未知）；`check*/clearData*/SetFirstWindow*/ApplicationActivated*` 是内部事件不是动作 |
| 窗口吸附 | ✅ 2026-10-28 | 1px 留边、50×50 门限同原版；自动吸附默认关 |
| 4–8 键 / 设备信息 / 按键识别 | ✅ 2026-10-28 | 不含 HID 厂商页宏键、被厂商驱动接管的键 |
| 权限向导 | ✅ 2026-10-28 | |
| 多语言（中/英） | ✅ 2026-10-28 | 跟随系统或手动选择 |
| iCloud 同步 | ❌ 已移除 2026-10-29 | 规则管理只留导入/导出/重置 |

（上文 §3 P1-c「触控板手势增强」与 P2「配置界面」已由上表各项覆盖。）

## 4. 验收清单（人工）

| 场景 | 期望 |
|---|---|
| Safari 里双键右拖 | 后退（页面历史变化） |
| Safari 里双键左拖 | 前进 |
| Finder 里双键右下拖 | 前台窗口最小化到 Dock |
| 双键左上拖 | 恢复该 App 最近最小化的窗口 |
| 双键 + A / V | 所有普通 App 窗口最小化 / 全部恢复 |
| 双键 + Shift+, | 前台 App 退出 |
| 右上角滚轮上/下 | 音量减/加 **各一次** |
| 左下角滚轮上/下 | 主屏亮度减/加 **各一次** |
| 快速连拨滚轮 | 不应出现几十次动作（已修复，回归用例 `corner burst fires once`） |
| 与 BetterAndBetter 同时运行 | 文档已提示会双触发，不作为 bug |
