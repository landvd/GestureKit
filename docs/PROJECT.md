# GestureKit 项目说明（交接文档）

> 给接手写代码的人/AI 看。读完这一份 + `PARITY.md` 就能直接开工。
> 版本：0.1.0（2026-10-28），作者：上一轮 agent，代码在 `Sources/`。

---

## 1. 背景与目标

原 App **BetterAndBetter 2.7.9**（better365.cn）从 2026-10-28 起会在启动时弹
「请更新 BetterAndBetter 至最新版。」，点确定后打开官网并让主程序退出，无法使用。

逆向结论（详见 `RE_APPENDIX.md`）：

- 弹窗来自登录项 `BetterAndBetterHelper`，它监听分布式通知
  `TellBetterAndBetterHelperToDownloadAgain`，收到就弹框，然后给主程序发
  `TellBetterAndBetterToQuit`。
- 主程序里的 `YLUpdateManager`（`ExpiredDate` / `ForceUpdateToTheLatest` /
  `MiniVersion` / `ExpiredOSVersion`）是**死代码**：运行时 `appID`、
  `appUpdateUrl`、`forceUpdateUrl` 全为 nil；二进制里也没有 2026-10-28 的日期。
- 已交付一个只改 Helper 一条分支的补丁（见 `../../README_patch.md`）。

**本项目的目标**：不依赖厂家，用自有代码实现一个等价工具，先覆盖用户实际在用的手势子集。

**明确边界**

- 不复制、不反编译复用厂家的任何代码、nib、图片、字符串资源。
- 不联网、不采集数据、不碰授权/账号。
- 所有行为都通过黑盒观察 + 公开 API 实现。

---

## 2. 当前状态（v0.1）

已实现并通过测试：

| 能力 | 状态 |
|---|---|
| 双键（左+右）按住 + 拖动 8 方向 | ✅ 已验证（真实事件回放） |
| 双键按住 + 按键（a…z、0…9、标点、Shift+, → `<`） | ✅ selftest |
| 热区 + 滚轮（四角 × 上/下） | ✅ selftest，含防连发 |
| 触控板双指横扫 | ⚠️ 依赖 `NSEvent.swipe`，部分 App 收不到 |
| 按前台 App 切换规则集 | ✅ |
| 动作：快捷键 / 窗口最小化·恢复·全部·全屏 / 退出 App / 音量 / 主屏亮度 | ✅ |
| 菜单栏：启用暂停 / 打开配置 / 重载 / 授权 / 开机自启 / 退出 | ✅ |
| 无权限时非模态重试（图标 `◈!`，5s 轮询） | ✅ |
| selftest 11 项 | ✅ 全绿 |

未实现：窗口贴边/移动、AppleScript 动作、运行命令、打开 App、剪贴板、媒体键、
外接屏亮度、图形化配置界面。见 `PARITY.md`。

---

## 3. 架构

```
                 ┌──────────────────────────────┐
 全局鼠标/键盘 ──▶│ CGEventTap (.cgSessionEventTap│
                 │  .defaultTap, headInsert)     │
                 └──────────────┬───────────────┘
                                │ CGEvent + type
                                ▼
                 ┌──────────────────────────────┐
                 │ GestureEngine.handle()        │  ← 状态机
                 │  • 双键 chord 状态             │
                 │  • 方向判定 / 双键+键          │
                 │  • 热区滚动 + 节流             │
                 └──────────────┬───────────────┘
                                │ ActionSpec
                                ▼
                 ┌──────────────────────────────┐
                 │ Actions.perform()             │
                 │  shortcut / window / quitApp  │
                 │  volume / brightness          │
                 └──────────────────────────────┘

 触控板双指 ── NSEvent.addGlobalMonitorForEvents(.swipe) ──▶ engine.handleTrackpadSwipe()
 配置      ── ~/Library/Application Support/GestureKit/rules.json（启动加载 / 菜单重载）
 权限      ── Accessibility（AXIsProcessTrusted），失败则 5s 重试直到授权
```

进程模型：单进程、`LSUIElement=true`（无 Dock 图标）、`NSStatusItem` 菜单栏。
无第三方依赖，纯 AppKit + ApplicationServices + ServiceManagement。

---

## 4. 模块逐个说明

### `Sources/Rules.swift`（114 行）

配置模型与默认值。

```swift
struct ActionSpec {          // 一个动作
    var type: String         // shortcut | window | quitApp | volume | brightness | none
    var keyCode: Int?        // shortcut: 虚拟键码（CGKeyCode）
    var modifiers: UInt32?   // shortcut: CGEventFlags 原始值
    var label: String?       // 人类可读，仅用于日志/文档
    var op: String?          // window: minimize|restore|minimizeAll|restoreAll|fullscreen
    var delta: Double?       // volume: ±音量百分比；brightness: ±0.0~1.0
}

struct Ruleset { var gestures: [String: ActionSpec] }
struct Config  { version, enabled, minDistance, cornerSize, rulesets }
```

- `Config.loadOrCreate()`：读 `~/Library/Application Support/GestureKit/rules.json`，
  不存在则写入 `Config.defaultConfig`。
- `Config.defaultConfig`：**按用户原 App 的配置预置**（见 `PARITY.md` 对照表）。
- `JSONEncoder.pretty`：`prettyPrinted + sortedKeys`，方便手改。

### `Sources/GestureEngine.swift`（207 行）核心

入口：`handle(type:event:) -> Unmanaged<CGEvent>?`，返回 `nil` 表示吞掉事件。

状态变量：

| 变量 | 含义 |
|---|---|
| `leftDown` / `rightDown` | 两个键当前是否按下 |
| `chordActive` | 双键手势进行中 |
| `chordStart` / `lastPoint` | 起点 / 最近位置（用于方向） |
| `chordMoved` | 位移是否超过 `minDistance` |
| `chordKeyFired` | 本次 chord 已触发过字母动作（避免重复） |
| `cornerAccum` / `lastCornerFire` | 热区滚动的累积量与节流时间 |

事件处理：

- `leftMouseDown`：记录；若右键已按 → 进入 chord。
- `rightMouseDown`：若左键已按 → 进入 chord 并**吞掉**（防止右键菜单）；否则正常放行。
- `left/rightMouseDragged`：chord 中则更新位置并吞掉。
- `left/rightMouseUp`：chord 中则结算（方向动作），吞掉。
- `keyDown`：chord 中且命中 `twoKey.key.<x>` → 执行并吞掉。
- `scrollWheel`：判断是否在屏幕角落 → 热区动作（累积 + 0.4s 节流）。

方向判定 `direction(from:to:)`：CG 坐标 y 向下；
`|dx| > 2|dy|` → left/right；`|dy| > 2|dx|` → up/down；否则四象限斜向。

`trackpad.swipeLeft/right`：`handleTrackpadSwipe(dx:dy:)`，要求 `|dx| > 1.5|dy|` 且 `|dx| > 1`。

规则集选择 `ruleset()`：`rulesetOverride ?? 前台 App bundleID`，命中则用专属，
否则 `"default"`。`rulesetOverride` 只给 selftest 用。

> ⚠️ 已知技术债：`draining` 只被赋值从未被读取（本意是 chord 结束后继续吞掉另一个
> 按键的 up）。行为上目前没发现问题，但补完更稳。

### `Sources/Actions.swift`（186 行）

- `shortcut`：`CGEvent(keyboardEventSource:virtualKey:keyDown:)` 造 down/up，
  设置 `flags` 后 post 到 `.cghidEventTap`。
- `window`：
  - `minimize`：前台 App 的 `AXFocusedWindow`（回退第一个窗口）设 `AXMinimized=true`。
  - `restore`：先前台 App 找 `AXMinimized=true` 的窗口恢复并 raise；找不到再遍历所有
    regular App。
  - `minimizeAll` / `restoreAll`：遍历 `NSWorkspace.shared.runningApplications`
    （`activationPolicy == .regular`）批量操作。
  - `fullscreen`：对 `AXFullScreen` 取反；失败回退发送 ⌃⌘F（keyCode 3 + ⌃⌘）。
  - AX 辅助：`axAttr` / `cfWindow`（`unsafeBitCast`）/ `windows(of:)`（CFArray 遍历）。
- `quitApp`：`NSWorkspace.shared.frontmostApplication?.terminate()`。
- `volume`：`NSAppleScript` 读当前音量、加减、夹到 0…100。
- `brightness`：`dlopen` DisplayServices，`DisplayServicesGetBrightness` /
  `SetBrightness`，只作用于 `CGMainDisplayID()`。
- `dryRun` / `observer`：测试钩子（`--selftest` 用 observer 断言；`--dry-run` 只打印）。

### `Sources/EventTap.swift`（74 行）

`CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
options: .defaultTap, ...)`。监听：左右键 down/up、drag、keyDown、scrollWheel。

- 用 `.defaultTap`（不是 listenOnly）才能吞事件。
- `tapDisabledByTimeout/UserInput` → 自动 `tapEnable` 重开。
- 主线程 RunLoop `.commonModes`。

### `Sources/AppDelegate.swift`（190 行）

- 启动：加载配置 → 状态栏 → 启动 tap（失败进重试）→ 装 swipe monitor → 请求权限。
- `tapFailed()`：图标变 `◈!`，只弹一次系统权限提示，然后 5s 重试直到成功。
- 菜单：启用（切换 `paused`）、打开配置、重载配置、授予权限、开机自启
  （`SMAppService.mainApp`）、退出。
- 日志见 `Log.swift`：`~/Library/Application Support/GestureKit/gesturekit.log`。

### `Sources/WindowLayout.swift`（新增）

窗口布局的纯几何：`halfLeft/halfRight/halfTop/halfBottom`、`quarterTopLeft…`、
`center/maximize`，按原版的**整数除法取半**，并提供 Cocoa→AX 坐标转换。
`--selftest` 里 6 条几何断言锁定（含 y 轴翻转）。

### `Sources/Shape.swift`（新增，约 200 行）

图形手势识别，按 `docs/ALGORITHMS_RECOVERED.md` 实现：

- `ShapeMatcher`：`stroke()`（去重+累计弧长）→ `normalized()`（平移/等比缩放+重采样 32 点）
  → `distance()`（弧长加权 DTW）→ `score()`（`max(0,1-2.5d)*100`，30pt 门限，
  模板按 1.0/0.78/1.3 横向比例取最高）。
- `GlyphLibrary`：22 个内置字形模板 + `glyph(forGestureID:)` 映射
  （`twoKey.key.a` → `A`，`twoKey.left` → `←`）。
- 阈值来自 `Config.shapeThreshold`（默认 85，与原版一致）。
- 调试：`--shape-debug` 打印各字形对给定笔画的得分。

### `Sources/Preferences.swift`（新增，约 700 行）

SwiftUI 实现的偏好设置窗口，按 `docs/UI_UX_SPEC.md` 复刻原版布局：

- `PrefPage`：侧栏 12 项（触控板/妙控鼠标/普通鼠标/键盘/边角触发/脚本库/黑名单/
  规则管理/通用设置/学习教程/免费 Apps/问题反馈），含 SF Symbol 与"是否设备页"。
- `PrefModel`：`ObservableObject`，持有 `Config`；`rows(for:)` 把规则摊平成表格行，
  并做**按页过滤**（corner.* / trackpad.* / twoKey.*）与**手势中文名映射**
  （`twoKey.left` → `按住右键 + ←`）。
- `PreferencesView`：侧栏 + 分段控件 + 卡片流 + 底部操作条；
  `card(_:symbol:tint:body:)` 是统一的圆角卡片容器。
- `PreferencesWindowController`：1000×700、隐藏标题栏、`NSHostingView` 承载。
- 已实现页面：普通鼠标（三段：按键识别/手势设置/平滑滚轮）、边角触发、通用设置、
  规则管理（iCloud + 导入导出）；其余页面为占位卡片。

页面进度：普通鼠标三段 / 边角 / 通用 / 规则管理 / **黑名单** 已实现；
触控板、妙控鼠标、键盘、脚本库、学习教程、免费 Apps、问题反馈为占位。

启动参数（调试用）：

```bash
GestureKit --prefs                 # 启动即打开偏好设置
GestureKit --prefs-page 边角触发    # 打开指定页（用侧栏标题）
```

### `Sources/main.swift`（129 行）

- `--selftest`：跑 11 项断言后 `exit`，不启动 GUI。
- `--dry-run`：动作只打印不执行。
- 正常：`NSApplication` + `.accessory` + `app.run()`。

### `GestureKit.app/Contents/Info.plist`

`LSUIElement=true`、bundle id `local.gesturekit.GestureKit`、
`NSAppleEventsUsageDescription`（音量用）、最低 macOS 13。

---

## 5. 配置格式

路径：`~/Library/Application Support/GestureKit/rules.json`

```jsonc
{
  "version": 1,
  "enabled": true,
  "minDistance": 24,      // 双键手势最小位移（pt）
  "cornerSize": 40,       // 热区边长（pt）
  "showHUD": true,        // 触发时提示备注/动作名（缺省 = true）
  "hudDuration": 0.5,     // HUD 停留秒数
  "smoothScroll": {       // 缺省 = 全部默认值（启用）
    "enabled": true, "speed": 3, "reverseX": false, "reverseY": false,
    "disabledApps": ["com.example.App"]
  },
  "windowDock": false,    // 拖到屏幕外缘自动吸附（默认关）
  "customGlyphs": {      // 自定义绘图手势的笔画（点数组 [x, y]）
    "1": [[0, 0], [100, 0], [100, 50]]
  },
  "rulesets": {
    "default": { "gestures": { "<gestureId>": <action> } },
    "com.apple.Safari": { "gestures": { ... } }
  }
}
```

手势 id：

```
twoKey.left|right|up|down|upLeft|upRight|downLeft|downRight
twoKey.key.<char>            // a-z 0-9 , . / ' [ ] - = ; \ `
twoKey.custom.<name>         // 自定义绘图手势，模板 = customGlyphs[name]
corner.<topLeft|topRight|bottomLeft|bottomRight>.<up|down>
trackpad.swipeLeft|swipeRight                  // 系统双指翻页（NSEvent.swipe）
trackpad.<1-5>f.tap                            // MultitouchSupport，见 TouchRecognizer
trackpad.1f.tap.<topLeft|top|topRight|left|center|right|bottomLeft|bottom|bottomRight>
trackpad.<2-5>f.swipe<Left|Right|Up|Down>[.from<Right|Left|Bottom|Top>]
trackpad.<2-5>f.pinchIn|pinchOut
magicMouse.1f.tap[.<zone>] / magicMouse.<2-3>f.tap        // 妙控鼠标表面
magicMouse.1f.click.<zone> / magicMouse.<1-3>f.click      // 手指放在上面时按下点按
magicMouse.2f.swipe<Left|Right|Up|Down>
```

带后缀的 id（边缘、九宫格）没有规则时回退到不带后缀的 id。

动作：

```jsonc
{ "type": "shortcut", "keyCode": 33, "modifiers": 1048576, "label": "⌘[" }
{ "type": "window", "op": "minimize" }   // minimize|restore|minimizeAll|restoreAll|fullscreen
{ "type": "quitApp" }
{ "type": "volume", "delta": -6 }
{ "type": "brightness", "delta": -0.0625 }               // 光标所在屏
{ "type": "brightness", "op": "external", "delta": 0.0625 } // 所有外接屏（DDC）；"builtin" = 内建屏
{ "type": "script", "script": "lib.applescript", "handler": "greet", "args": ["Bob"] }
// 任意动作都可带：
"note": "备注",        // HUD 优先显示；只含空格 = 不提示
"enabled": false       // 保留但不触发（缺省 = 启用）
```

`modifiers`：⌘ 1048576、⌥ 524288、⌃ 262144、⇧ 131072（可相加）。

---

## 6. 测试方法（三层）

### 6.1 单元级：`--selftest`（必须全绿）

```bash
./GestureKit.app/Contents/MacOS/GestureKit --selftest
```

用 `CGEvent(...)` 构造合成事件喂给 `GestureEngine.handle`，用 `Actions.observer`
收集动作断言。不触碰真实输入，可在无权限环境跑。

现有 11 项：右拖 ⌘[、左拖 ⌘]、右下最小化、左上恢复、左下 ⌃⌘F、双键+A、双键+V、
双键+Shift+,、热区音量、**热区连发只触发一次**、横扫 ⌘[。

> 新增手势/动作必须同步加断言，且用 `makeEngine()`（内部设 `rulesetOverride`），
> 否则测试会受"当前前台 App"影响。

### 6.2 集成级：真实事件回放

```bash
# /tmp/chord.c：post 左down→右down→拖→左up→右up
clang -framework ApplicationServices -o /tmp/chord /tmp/chord.c
./GestureKit.app/Contents/MacOS/GestureKit --dry-run &
/tmp/chord
cat ~/Library/Application\ Support/GestureKit/gesturekit.log
```

期望日志出现 `[dry-run] action ... key=33`。这一步验证 tap 真的收到了系统事件。

### 6.3 人工验收

菜单栏 `◈` → 逐条试 `PARITY.md` 的验收表；日志里每笔 `action type=...` 可核对
次数与方向（热区误连发就是靠这个发现的）。

---

## 7. 已知问题 / 技术债

1. `draining` 未被使用；chord 结束后另一个按键的 up 仍会放行。
2. 全屏 Action 依赖 `AXFullScreen`，个别 App 不支持时回退 ⌃⌘F。
3. 外接显示器亮度未实现（原 App 有 `External Screen Brightness*`）。
4. 触控板横扫用 `NSEvent.swipe`，Chrome/Electron 等可能收不到；备选方案：
   `scrollWheel` 的 `phase`/`momentumPhase` 判方向。
5. 热区判定用 `NSScreen.screens.first` 作为主屏高度基准，多屏坐标需要再验证。
6. ad-hoc 签名时重新编译会改变 cdhash，**Accessibility 权限失效**。
   **已解决（2026-10-28）**：运行一次 `scripts/make-signing-cert.sh` 生成自签证书
   "GestureKit Self-Signed"，之后 `build.sh` 自动用它签名，TCC 绑定「bundle id + 证书」，
   重编译不再掉权限（从 ad-hoc 切到证书那一次仍需授权一次）。没有证书时照旧 ad-hoc。
7. 没有 UI；配置只能手改 JSON。
8. 与 BetterAndBetter 同时运行会双触发，文档已提示。
9. `AppDelegate.configWatch` 声明未使用（预留热重载）。
10. 音量走 AppleScript，每次约 50–100ms；高频场景可换 CoreAudio。

---

## 8. 路线图（建议按此顺序）

**P0（先把日常用顺）**
- [ ] 补完 `draining`，确保 chord 不产生杂散点击
- [ ] 多屏热区坐标验证 + 单测
- [ ] 触控板横扫改滚轮相位实现（更通用），保留 NSEvent 作为回退
- [ ] 图形化状态反馈：动作触发时在鼠标附近闪一个小 HUD（0.5s）

**P1（补齐原 App 高频功能）**
- [ ] 窗口贴边/半屏/移动（AX `AXPosition`/`AXSize`，参考 `PARITY.md` 的 8 个方位）
- [ ] 打开 App / 打开文件 / 运行 shell / AppleScript 动作
- [ ] 模拟按键序列（多步宏）
- [ ] 媒体键（播放/暂停/上一首/下一首，`NX_KEYTYPE_*`）
- [ ] 外接屏亮度（DDC/CI 或 `DisplayServices` 逐 display）

**P2（工程化）**
- [ ] 图形化配置面板（SwiftUI）
- [ ] 配置 schema 校验 + 迁移（`version` 字段已预留）
- [ ] 稳定签名证书，避免每次改代码都要重授权
- [ ] 崩溃/异常日志落盘 + 一键导出诊断

**验收标准**：每项都要有 selftest 断言；P1 的窗口动作需在 Safari/Finder/VS Code
三个 App 上人工验证。

---

## 9. 构建 / 签名 / 安装

```bash
cd ~/Documents/DSH/GestureKit
scripts/make-signing-cert.sh   # 仅首次：创建自签签名证书（需本机图形界面确认）
./build.sh                  # 编译 + selftest + 签名（有证书用证书，否则 ad-hoc）
cp -R GestureKit.app /Applications/   # 安装
open -a /Applications/GestureKit.app
```

**权限**：`build.sh` 最后会打印签名身份。
- `身份：cdhash H"…"` → ad-hoc，每次重新编译都要去「辅助功能」重新授权；
- `身份：identifier "local.gesturekit.GestureKit" and certificate leaf = H"…"` → 证书签名，
  授权一次长期有效。换证书或改 bundle id 才需要重新授权。
- 用别的证书：`GK_SIGN_IDENTITY="证书名" ./build.sh`。

---

## 10. 目录结构

```
GestureKit/
├── CLAUDE.md              # 给编码 agent 的速查（先读它）
├── README.md              # 用户向说明
├── build.sh               # 编译 + 测试 + 签名
├── scripts/make-signing-cert.sh  # 一次性创建自签签名证书
├── scripts/check-l10n.sh  # 检查所有 L("…") 都有英文（build.sh 会调用）
├── docs/
│   ├── PROJECT.md         # 本文件
│   ├── PARITY.md          # 与原 App 的功能对照 + 实现建议
│   └── RE_APPENDIX.md     # 原 App 逆向结论（背景资料）
├── Sources/
│   ├── Rules.swift
│   ├── GestureEngine.swift
│   ├── Actions.swift
│   ├── EventTap.swift
│   ├── AppDelegate.swift
│   ├── Log.swift
│   ├── ActionCatalog.swift   # 动作/按键中文名 + 编辑器可选动作（HUD/设置共用）
│   ├── HUD.swift             # 光标旁提示
│   ├── SmoothScroll.swift    # 平滑滚轮（离散滚轮 → 120Hz 像素滚动）
│   ├── Multitouch.swift      # MultitouchSupport 设备层（dlopen）
│   ├── TouchRecognizer.swift # 多指帧 → trackpad.<N>f.* 手势 id（纯逻辑，可测）
│   ├── RuleEditor.swift      # 规则添加/编辑面板（含自定义绘图画板）
│   ├── ConfigIO.swift        # 导入/导出/合并/备份
│   ├── ScriptRunner.swift    # 脚本库：解析路径 + AppleScript/shell 执行
│   ├── DisplayBrightness.swift # 亮度：DisplayServices + DDC/CI（IOAVService）
│   ├── WindowDock.swift      # 窗口吸附（状态机 + AX 驱动，驱动可替换以便自检）
│   ├── HIDMouse.swift        # IOHID 设备枚举/插拔、按键名、按键识别页数据（不 open 设备）
│   ├── PermissionWizard.swift # 辅助功能权限向导（状态机 + SwiftUI 窗口）
│   ├── CloudSync.swift       # iCloud 云盘文件夹同步（哈希判定、防回环）
│   ├── L10n.swift            # 中/英文案表与语言选择
│   ├── SelfTestSuites.swift  # 分区域自检注册；各区域断言在 SelfTest+<区域>.swift
│   └── main.swift
└── GestureKit.app/        # 构建产物（Info.plist 在仓库里）
```
