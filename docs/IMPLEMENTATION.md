# 实现手册（怎么把规格做出来）

> 配套 `ORIGINAL_FEATURES.md`（做什么）。本文是**总览**：架构、数据流、快速对照。
> 逐模块的详细工程规格见 **`modules/`**（15 个模块，含算法、边界、测试点、代码骨架）。

---

## 模块索引（详细实现）

| # | 模块 | 文件 |
|---|---|---|
| 01 | 全局事件采集 | `modules/01-input-eventtap.md` |
| 02 | HID / 鼠标按键 | `modules/02-input-hid-mouse.md` |
| 03 | 多指触控 | `modules/03-input-multitouch.md` |
| 04 | 鼠标手势识别 | `modules/04-recognizer-mouse.md` |
| 05 | 触控板手势识别 | `modules/05-recognizer-touch.md` |
| 06 | 边角 + 绘图 | `modules/06-hotcorner-drawing.md` |
| 07 | 规则引擎 | `modules/07-rules-engine.md` |
| 08 | 窗口动作 | `modules/08-actions-window.md` |
| 09 | 系统动作 | `modules/09-actions-system.md` |
| 10 | 输入类动作 | `modules/10-actions-input-script.md` |
| 11 | 平滑滚轮 | `modules/11-smooth-scroll.md` |
| 12 | HUD | `modules/12-hud.md` |
| 13 | 存储/同步 | `modules/13-storage-sync.md` |
| 14 | 权限/生命周期 | `modules/14-permissions-lifecycle.md` |
| 15 | 测试/性能 | `modules/15-testing-performance.md` |

---

## 0. 总体架构

```
┌─────────────────────────────────────────────────────────────┐
│ 采集层 InputSource                                           │
│  CGEventTap(鼠标/键盘/滚轮)   Multitouch(触控板)   NSEvent    │
└───────────────┬─────────────────────────────────────────────┘
                │ 归一化事件 InputEvent {device, code, phase, point, flags, fingers}
                ▼
┌─────────────────────────────────────────────────────────────┐
│ 识别层 Recognizer                                            │
│  每设备一个状态机：chord / 方向 / 按住 / 多指 / 绘图          │
│  输出 GestureEvent {device, gestureID, modifier, at}          │
└───────────────┬─────────────────────────────────────────────┘
                ▼
┌─────────────────────────────────────────────────────────────┐
│ 规则层 RuleEngine                                            │
│  frontmost app → ruleset → (gestureID+modifier) → ActionSpec  │
│  黑名单 / 优先级 / EnableUnderCursor                          │
└───────────────┬─────────────────────────────────────────────┘
                ▼
┌─────────────────────────────────────────────────────────────┐
│ 执行层 ActionRunner + HUD                                    │
└─────────────────────────────────────────────────────────────┘
```

线程模型建议：

- 事件 tap 回调、多指回调都**在专用串行队列**处理，只做轻量识别，重活
  （AppleScript、AX 批量操作）派发到主队列或后台队列。
- 所有 UI（HUD、设置窗）只在主线程。

---

## 1. 采集层

### 1.1 CGEventTap（鼠标 / 键盘 / 滚轮）

```swift
let mask: CGEventMask =
    (1 << CGEventType.leftMouseDown.rawValue)  |
    (1 << CGEventType.leftMouseUp.rawValue)    |
    (1 << CGEventType.rightMouseDown.rawValue) |
    (1 << CGEventType.rightMouseUp.rawValue)   |
    (1 << CGEventType.otherMouseDown.rawValue) |   // 中键/4~8 键
    (1 << CGEventType.otherMouseUp.rawValue)   |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.rightMouseDragged.rawValue) |
    (1 << CGEventType.otherMouseDragged.rawValue) |
    (1 << CGEventType.scrollWheel.rawValue)    |
    (1 << CGEventType.keyDown.rawValue)        |
    (1 << CGEventType.keyUp.rawValue)          |
    (1 << CGEventType.flagsChanged.rawValue)   |
    (1 << CGEventType.mouseMoved.rawValue)

let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,          // 需要吞事件时必须 defaultTap
    eventsOfInterest: mask,
    callback: callback,
    userInfo: Unmanaged.passUnretained(self).toOpaque())
CFRunLoopAddSource(CFRunLoopGetMain(),
                   CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
```

关键字段：

| 事件 | 读取 |
|---|---|
| 按键号 | `event.getIntegerValueField(.mouseEventButtonNumber)`（0=左 1=右 2=中 3~7=4~8 键） |
| 点击次数 | `.mouseEventClickState`（双击/多击） |
| 光标位置 | `event.location`（左上原点） |
| 修饰键 | `event.flags`（`.maskCommand/.maskShift/.maskControl/.maskAlternate/.maskSecondaryFn`） |
| 滚轮 | `.scrollWheelEventPointDeltaAxis1/2`、`.scrollWheelEventScrollPhase`、`.scrollWheelEventMomentumPhase` |
| 键盘 | `.keyboardEventKeycode` + `flagsChanged` |

**吞事件**：回调返回 `nil` 即丢弃。原则：

- 只在"手势被占用"期间吞（chord 中的第二个键按下/抬起、被规则消费的字母键）。
- 任何异常/超时立刻恢复放行，避免把用户鼠标卡死。
- tap 被系统禁用（`.tapDisabledByTimeout`）要立刻 `CGEvent.tapEnable(tap:enable:true)`。

### 1.2 触控板多指

**方案 A（推荐，兼容性好）**：`NSEvent` 手势

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.swipe, .magnify, .rotate, .gesture]) { e in
    // e.deltaX/deltaY 方向；e.magnification 捏合；e.rotation 旋转
}
```
拿不到"几根手指"和精确接触点，只能做 Swipe/Pinch 这类高层手势。

**方案 B（完整，需私有框架）**：`MultitouchSupport.framework`

```swift
typealias MTDeviceCreateListFn = @convention(c) () -> CFArray
typealias MTRegisterContactFrameCallbackFn =
    @convention(c) (OpaquePointer, @convention(c) (OpaquePointer, UnsafePointer<Finger>, Int32, Double, Int32) -> Void) -> Void
// Finger: { int frame; double x,y; double size; int pressure... }（不同系统字段略有差异）

let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
// 遍历设备、注册回调，回调里拿到每根手指的 x/y/size/pressure
```

用途：手指数量、接触面积（指尖/指腹）、质心、轨迹 → 才能实现
`TipTap`、`EdgeSwipe`、`Pinch`、绘图、三指模拟中键。
代价：私有 API、系统升级可能变、上架 App Store 会被拒（自用/直接分发没问题）。

### 1.3 妙控鼠标

- 表面触摸 = 同一套 `MultitouchSupport`（Magic Mouse 也是一块触摸面）。
- 物理按键 = `otherMouseDown`（中键/侧键）+ `IOHIDManager` 读原始 usage。
- 三指按下模拟中键：检测到"3 指接触 + 压力/点击"后，合成 `otherMouseDown(button 2)`
  并接管后续 `mouseDragged`（把触摸位移映射成光标移动）。

### 1.4 键盘

- `keyDown/keyUp` + `flagsChanged`。
- 组合键识别就是 `(keyCode, flags)` 二元组匹配。
- "按住 N 键"用 keyDown 时间戳 + 定时器判定。

---

## 2. 识别层

### 2.1 鼠标按键状态机（chord）

```swift
struct MouseState {
    var down: Set<Int> = []          // 当前按下的按键号
    var startPoint = CGPoint.zero
    var maxDistance: CGFloat = 0
    var downTime = Date()
    var consumed = false             // 已被手势消费
}

func onMouseDown(_ button: Int, at p: CGPoint) {
    state.down.insert(button)
    if state.down.count == 1 { state.startPoint = p; state.downTime = Date(); state.consumed = false }
    if state.down.count >= 2 { suppressNextUp.insert(button) }   // 双键起手
}

func onMouseUp(_ button: Int, at p: CGPoint) {
    state.down.remove(button)
    if state.down.isEmpty, !state.consumed {
        let dir = direction(from: state.startPoint, to: p)       // 8 向
        if state.maxDistance >= minDistance, let g = dir { fire("\(dir)Of2Key") }
        else if Date().timeIntervalSince(state.downTime) >= 0.5 { fire("\(button)KeyDownning") }
    }
}
```

要点：

- `minDistance` / `distanceOfStartDragged`：前 N 像素不参与方向判定（防手抖）。
- 8 向判定：`|dx| > 2|dy|` → 水平；`|dy| > 2|dx|` → 垂直；否则对角。
- 双键 + 字母：chord 期间 `keyDown` 命中字母 → 触发并吞掉该键。
- 按住（Downning）：定时器在按住 0.5s 时触发一次，抬手不重复。

### 2.2 多指手势识别

```swift
struct Touch { var id: Int32; var x: CGFloat; var y: CGFloat; var size: CGFloat }

func onFrame(_ touches: [Touch], timestamp: Double) {
    guard !touches.isEmpty else { endGesture(); return }
    centroid = average(touches)
    spread   = meanDistance(touches, centroid)

    switch phase {
    case .began:
        startCentroid = centroid; startSpread = spread; startTime = timestamp
        fingerCount = touches.count
    case .moved:
        let dx = centroid.x - startCentroid.x
        let dy = centroid.y - startCentroid.y
        if hypot(dx, dy) > threshold, !fired {
            fire("\(fingerCount)Finger_Swipe_\(direction(dx, dy))"); fired = true
        }
        if abs(spread - startSpread) > pinchThreshold, !fired {
            fire(spread > startSpread ? "\(n)Finger_Pinch_Out" : "\(n)Finger_Pinch_In"); fired = true
        }
    case .ended:
        if !fired, duration < 0.25, maxMove < tapSlop {
            fire("\(fingerCount)Finger_Tap\(zoneSuffix(at: startCentroid))")
        }
    }
}
```

细分规则：

| 手势 | 判定 |
|---|---|
| `Tap` | 接触 < 250ms、位移 < 8pt |
| `Click` | 有物理按压（pressure 突增） |
| `ForceClick` | 压力超过阈值（`kCGEventPressure` 或私有字段） |
| `DoubleTap` | 两次 Tap 间隔 < 300ms |
| `Swipe` | 位移 > 40pt，方向占优 |
| `Swipe_From <Edge>` | 起点在边缘带（`distanceToTrackPadSides`）内 |
| `TipTap_*` | 接触面积 < 阈值（指尖）且位置落在分区 |
| `Pinch_In/Out` | `spread` 变化率 |
| 三指拖拽 | 3 指接触后整体平移 → 合成 `leftMouseDragged` |

区域划分（`1Finger_Tap_*` 的 9 宫格 + 边）：按归一化坐标切 3×3，边带再细分。

### 2.3 绘图手势匹配

```swift
struct Stroke { var points: [CGPoint]; var angles: [CGFloat]; var duration: Double }

// 录制：每 8ms 采样，去噪 → 重采样到 N=32 点 → 计算相邻段角度
// 匹配：加权比较
func similarity(_ a: Stroke, _ b: Stroke) -> Double {
    let angleScore = cosineSimilarity(a.angles, b.angles)       // 权重 0.6
    let shapeScore = procrustesDistance(a.points, b.points)     // 权重 0.3（归一化后）
    let timeScore  = 1 - min(abs(a.duration - b.duration) / 2, 1) // 权重 0.1
    return 0.6 * angleScore + 0.3 * (1 - shapeScore) + 0.1 * timeScore
}
// score > 0.85 视为命中；多模板取最高分
```

要点：起点归一化、按包围盒缩放、允许旋转（角度差取绝对值）、限制模板数量。

---

## 3. 动作执行层

### 3.1 快捷键

```swift
func sendShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)!
    let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)!
    down.flags = flags; up.flags = flags
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
}
```

媒体键/亮度键（不是普通 keyCode）：

```swift
func sendSystemKey(_ type: Int32) {   // NX_KEYTYPE_PLAY=16, SOUND_UP=0, BRIGHTNESS_UP=2...
    let flags = 0xa00 << 16
    for down in [true, false] {
        let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                   modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                   timestamp: 0, windowNumber: 0, context: nil,
                                   subtype: 8, data1: Int((type << 16) | (down ? 0xa : 0xb)),
                                   data2: -1)!
        e.cgEvent!.post(tap: .cghidEventTap)
    }
}
```

### 3.2 窗口操作（AX）

```swift
func axSet(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) {
    AXUIElementSetAttributeValue(el, attr as CFString, value)
}

func snap(_ win: AXUIElement, to rect: CGRect) {
    var p = rect.origin, s = rect.size
    axSet(win, kAXPositionAttribute as String, AXValueCreate(.cgPoint, &p)!)
    axSet(win, kAXSizeAttribute as String,     AXValueCreate(.cgSize, &s)!)
}

// 半屏：用目标屏的 visibleFrame（已排除菜单栏/Dock）计算
// 左半：x=v.minX, y=v.minY, w=v.width/2, h=v.height
// 上/下/四角同理；多屏用 NSScreen.screens + 窗口当前屏幕
```

坐标：`AXPosition` 与 `NSScreen` 都是**左上原点**（与 CGEvent 一致），
但 `NSScreen.frame` 是左下原点 → 需要 `mainHeight - y - h` 转换。

全屏：`AXFullScreen` 取反；失败回退 ⌃⌘F。
跨屏移动：计算目标屏 visibleFrame 后 setPosition。
恢复最小化：遍历 `AXWindows` 找 `AXMinimized==true` → 置 false + `AXRaise`。

### 3.3 打开目标 / 文本 / 菜单

```swift
// 打开 App / 文件 / URL
NSWorkspace.shared.open(url)
NSWorkspace.shared.openApplication(at: appURL, configuration: .init())

// 输入文本（分段，避免超长）
let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
e.keyboardSetUnicodeString(stringLength: n, unicodeString: buf)
e.post(tap: .cghidEventTap)

// 点击菜单：AX 遍历菜单栏 → 匹配标题路径 → AXPress
```

### 3.4 AppleScript

```swift
let script = NSAppleScript(source: source)!
var err: NSDictionary?
let result = script.executeAndReturnError(&err)
```

- 脚本库：把 `.scpt` 放 `~/Library/Application Support/<App>/Scripts/`，用
  `NSAppleScript(contentsOf:error:)` 加载。
- 需要发 Apple Events 的，Info.plist 加 `NSAppleEventsUsageDescription`，
  首次执行系统会弹自动化授权。

### 3.5 系统动作

| 动作 | 实现 |
|---|---|
| 锁屏 | `dlopen` + `SACLockScreenImmediate()` |
| 睡眠 | `IOPMSleepSystem(IOPMConnectionCreate(...))` |
| 清空废纸篓 | 遍历 `~/.Trash` `FileManager.removeItem`（可加确认框） |
| 显示/隐藏 Dock | 写 `com.apple.dock autohide` + `killall Dock`（或用 `AX` 菜单） |
| 显示/隐藏桌面文件 | `chflags hidden/nohidden ~/Desktop/*` |
| 显示桌面 | 合成 F11 / `CGEvent` 双击桌面 |
| Mission Control / Launchpad | `open -a "Mission Control"` / `open -a Launchpad` |
| 截图 | `/usr/sbin/screencapture -i/-w/-W`（区域/窗口/滚动需额外逻辑） |

### 3.6 音量 / 亮度

```swift
// 音量：CoreAudio（AudioObjectSetPropertyData, kAudioHardwareServiceDeviceProperty_VirtualMainVolume）
// 或快速方案：osascript set volume output volume N

// 内置屏亮度：DisplayServices 私有
//   DisplayServicesGetBrightness(displayID, &v)
//   DisplayServicesSetBrightness(displayID, v)

// 外接屏亮度：DDC/CI
//   IOAVServiceCreateWithService → IOAVServiceWriteI2C(0x37, 0x51, ...)
//   或 dlsym "DisplayServicesSetBrightness" 对 CGGetActiveDisplayList 逐个尝试
```

### 3.7 模拟触控板手势

- Free Scroll：合成 `scrollWheel` 事件，按时间片线性增加 delta，带 `phase`。
- Zoom/Rotate：合成 `magnify` 事件（`CGEvent` 无直接 API，用 `NSEvent` +
  `CGEventCreateCopy` 或私有 `CGEventSetIntegerValueField` 的 gesture 字段）。

---

## 4. 平滑滚轮

```swift
// tap 里拦截 scrollWheel，不改系统设置，只重写 delta
func onScroll(_ e: CGEvent) -> CGEvent? {
    guard smoothEnabled, !modifierPaused(app: frontApp) else { return e }
    let raw = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let target = raw * speed                       // speed 0.5~2.0
    // 用 120Hz 定时器把 target 拆成多帧小 delta，逐帧 post 到 cghidEventTap
    // 返回 nil 吞掉原始事件
}
```

要点：

- 必须吞原始事件，否则会双倍滚动。
- 帧率固定 120Hz，剩余量累积，避免丢步。
- 按住 ⌃⌥⌘ 任一修饰键时暂停（`disableSmoothScrollOfHoldingModifierkey`）。
- 按 App 单独配置（`SmoothScrollIndividualSetting`）。
- 与 Logitech 驱动冲突要特例处理（有专门键）。

---

## 5. 规则引擎

```swift
struct RuleKey: Hashable { let gesture: String; let modifier: String }

func resolve(gesture: String, modifier: String) -> ActionSpec? {
    let app = frontmostBundleID()                       // 或窗口所在 App
    if let r = rulesets[app]?[RuleKey(gesture, modifier)] { return r }
    if let r = rulesets["default"]?[RuleKey(gesture, modifier)] { return r }
    return nil
}
```

- 修饰键归一化：`-` / `⌘` / `⌥` / `⌃` / `⇧`，组合按固定顺序拼接。
- `EnableUnderCursor`：执行前用 `AXUIElementCopyElementAtPosition` 找光标下窗口，
  `AXRaise` + 激活其 App，再执行。
- 黑名单：`frontmostBundleID ∈ globalBlacklist` → 整体 return；按键黑名单按
  `(bundleID, button)` 过滤。
- 只在规则命中时才吞事件。

---

## 6. HUD

```swift
final class HUD {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    func show(_ text: String, at point: CGPoint) {
        panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        // 圆角 + NSVisualEffectView + NSTextField
        // 定位：point 偏移 (12, -12)，超出屏幕则翻转
        // 动画：alpha 0→1，停留 retentionTime 后 1→0
    }
}
```

---

## 7. 数据与同步

- 配置用 JSON（可读、易迁移）；规则表结构见规格书 5.2。
- `version` 字段做迁移：读旧版 → 转换 → 写新结构。
- 导入/导出：整包 JSON；预设按模块导入（普通鼠标/妙控鼠标/触控板/键盘/边角/脚本）。
- iCloud：
  - 轻量：`NSUbiquitousKeyValueStore`（1MB 上限，够规则用）
  - 完整：CloudKit `privateDB` 存 JSON 文件
  - 冲突：以 `updatedAt` 新者胜，或提示用户选择。

---

## 8. 权限与生命周期

```swift
// 辅助功能
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
AXIsProcessTrustedWithOptions(opts)

// 屏幕录制（截图/录屏用）
CGPreflightScreenCaptureAccess() / CGRequestScreenCaptureAccess()

// 输入监控：CGEventTap 创建失败时引导用户
// 完全磁盘：引导到 系统设置→隐私→完全磁盘访问

// 登录项
try SMAppService.mainApp.register()
```

首次启动做"权限向导"：逐项检查 → 图文步骤 → 一键跳转系统设置 → 轮询状态。

---

## 9. 性能与稳定性

- tap 回调里禁止：文件 IO、网络、`NSAlert`、长时间循环。目标 < 1ms。
- 事件处理异常要 `try/catch` 兜底并**放行**事件。
- tap 被禁用（超时）自动重开；连续失败降级为 listen-only 并提示。
- AppleScript / AX 批量操作放后台串行队列，主线程只做 UI。
- 日志分级 + 环形缓冲（避免写爆磁盘）。

---

## 10. 测试方法

| 层级 | 方法 |
|---|---|
| 单元 | 识别器纯函数（方向判定、区域划分、绘图相似度、修饰键归一化） |
| 集成 | 合成 `CGEvent` 注入（按下/移动/抬起、滚轮、按键），断言触发的 ActionSpec |
| 真机 | 每类设备各验证一遍：普通鼠标 / 妙控鼠标 / 触控板 / 键盘 / 边角 |
| 回归 | 每个 bug 补一条合成事件用例 |

代码骨架（合成事件驱动识别器）：

```swift
func testChordRight() {
    var fired: [String] = []
    let r = Recognizer { fired.append($0) }
    r.mouseDown(0, at: .init(x: 600, y: 400))
    r.mouseDown(1, at: .init(x: 600, y: 400))
    r.mouseDragged(to: .init(x: 720, y: 400))
    r.mouseUp(0, at: .init(x: 720, y: 400))
    r.mouseUp(1, at: .init(x: 720, y: 400))
    XCTAssertEqual(fired, ["rightOf2Key"])
}
```

---

## 11. 推荐目录（复刻版）

```
Sources/
├── App/            AppDelegate, StatusItem, PreferencesWindow
├── Input/          EventTap, HID, Multitouch, Keyboard
├── Recognize/      MouseRecognizer, TouchRecognizer, HotCorner, DrawingMatcher
├── Rules/          RuleStore, RuleEngine, Blacklist, Presets
├── Actions/        ActionRunner, Keyboard, Window, System, Script, Open, Text
├── Features/       SmoothScroll, HUD, InputSourceSwitch, Brightness
├── Storage/        Config, Migration, ICloudSync
└── Support/        Permissions, Log, Geometry
```

---

## 12. 快速对照：功能 → 实现要点

| 功能 | 关键实现 |
|---|---|
| 双键 + 方向 | CGEventTap + chord 状态机 + 8 向判定 + 吞事件 |
| 双键 + 字母 | chord 期间 keyDown 匹配 + 吞键 |
| 按住 N 键 | 定时器 0.5s + 去重 |
| 滚轮四向 | scrollWheel + 轴/方向 + 节流 |
| 触控板 1–5 指 | MultitouchSupport 接触点 → 数量/质心/扩散 |
| 边缘滑入 | 起点落在边缘带 |
| 指尖轻点 | 接触面积阈值 + 区域划分 |
| 捏合 | spread 变化率 |
| 三指模拟中键 | 3 指 + 按压 → 合成 otherMouseDown + 拖拽接管 |
| 妙控鼠标手势 | Multitouch（触摸面）+ otherMouse（按键） |
| 绘图 | 采样 → 重采样 → 角度序列 → 相似度 |
| 屏幕边角 | 鼠标位置 + 边角几何 + 滚轮触发 |
| 平滑滚轮 | 拦截 + 重写 delta + 120Hz 插值 |
| 黑名单 | bundleID 匹配 + 状态挂起 |
| HUD | 无边框 NSPanel + 定时淡出 |
| iCloud | NSUbiquitousKeyValueStore / CloudKit |
| 开机自启 | SMAppService |
| 外接屏亮度 | DDC/CI（IOAVService） |
```
