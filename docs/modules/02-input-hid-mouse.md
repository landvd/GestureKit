# 模块 02 · HID 设备与鼠标按键（IOHIDManager）

## 为什么需要
`CGEventTap` 只能看到"标准 5 键"（左/右/中 + 2 个侧键），很多鼠标的 6/7/8 键、
滚轮左右倾斜、厂商自定义键不会映射成 `otherMouseDown`。要支持 8 键必须走 HID。

## 职责
- 枚举/监听 HID 设备（鼠标、妙控鼠标、触控板）
- 把 HID usage 映射成逻辑按键号 3..7（4..8 键）
- 提供设备信息（厂商/型号/产品 ID/传输方式）用于"鼠标适配"界面

## 依赖
- `IOKit.hid`（`IOHIDManagerCreate`、`IOHIDManagerRegisterInputValueCallback`）
- 权限：输入监控（macOS 10.15+ 读 HID 需要）

## 关键 API
```swift
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(mgr, [
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
     kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
     kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
] as CFArray)
IOHIDManagerRegisterInputValueCallback(mgr, { ctx, ret, sender, value in
    let el = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(el)
    let usage = IOHIDElementGetUsage(el)
    let intValue = IOHIDValueGetIntegerValue(value)
    // usagePage == kHIDPage_Button && intValue != 0 → 按键按下
}, ctx)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), .commonModes)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
```

## usage → 逻辑键号
| HID Button usage | 逻辑键 | 说明 |
|---|---|---|
| 1 | 左键 (0) | 通常也走 CGEvent |
| 2 | 右键 (1) | 同上 |
| 3 | 中键 (2) | 同上 |
| 4 | 4 键 (3) | 只走 HID |
| 5 | 5 键 (4) | 只走 HID |
| 6..8 | 6..8 键 (5..7) | 只走 HID |

**去重**：左/右/中键会同时出现在 CGEvent 和 HID，选一路（建议 CGEvent 为主，
HID 只补 4..8 键），避免重复触发。

## 妙控鼠标
- 触摸面 = 多指模块（见 03）；物理按键 = HID/CGEvent。
- 三指按下模拟中键：需要"3 指接触 + 压力/点击"→ 合成 `otherMouseDown(button 2)`，
  后续触摸位移映射为光标移动，直到抬起。

## 设备信息（用于适配界面）
```swift
IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString)      // 型号
IOHIDDeviceGetProperty(dev, kIOHIDManufacturerKey as CFString) // 厂商
IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString)    // PID
IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString)    // USB/Bluetooth
```

## 边界与错误
- 无输入监控权限：`IOHIDManagerOpen` 返回 `kIOReturnNotPermitted` → 引导授权。
- 设备热插拔：监听 `IOHIDManagerRegisterDeviceMatchingCallback/RemovalCallback`。
- 罗技等厂商驱动会"吞"按键：文档提示用户卸载驱动（原版就有这句提示）。
- 6/7/8 键在部分鼠标上是"宏键"，HID 里可能是 Consumer Page，需要兼容。

## 测试点
- 拔插设备后仍能收到按键
- 4..8 键与 CGEvent 不重复触发
- 无权限时不崩溃、给出引导

## 实现（2026-10-28，P2-12）

**权限取舍**：只做枚举 + 插拔监听，不读 HID 输入值。
`IOHIDManagerSetDeviceMatchingMultiple` → `IOHIDManagerCopyDevices` / `IOHIDDeviceGetProperty` /
`IOHIDDeviceCopyMatchingElements`（读报告描述符算按键数）都**不需要** `IOHIDManagerOpen`，
实测不触发「输入监控」(ListenEvent) 请求；代码里从不调用 `IOHIDManagerOpen` / `IOHIDDeviceOpen` /
`RegisterInputValueCallback`。旧 `DeviceInfo` 里的 `IOHIDManagerOpen` 已删除。
`IOHIDCheckAccess` 只用于查询（不弹窗）。

**4–8 键**：`EventTap.eventMask` 增加 `otherMouseDown/Up/Dragged`，中键与侧键按
`mouseEventButtonNumber` 进入 `GestureEngine`（引擎未改）。单独按一个键 → 放行；
已有一个键按住时再按第二个键 → 组合手势，第二个键的 down 与之后的拖动/抬起被吞。
CGEvent 看不到的键（只走 HID 厂商页的宏键、被 Logi Options+ 等驱动接管的键）暂不支持。

**文件**
- `Sources/HIDMouse.swift`：`HIDMouseInfo`（产品/厂商/VID/PID/传输/按键数/内建/类型）、
  `HIDMouse.parse/merge/preferred/enumerate`（纯函数可测；Mouse+Pointer 多接口按 VID:PID:LocationID 去重）、
  `HIDMouseMonitor`（match/removal 回调 → `HIDMouseMonitor.changed` 通知，只在「按键识别」页可见时运行）、
  `MouseButtons`（按键号 → 中文名）、`MouseButtonFeed`（tap 回调里观察按键，页面可见才广播，异步投递，不改事件）、
  `ButtonAdaptation`（手动适配：记录除左键外每个键的按键号，只展示不持久化）。
- `Sources/DeviceInfo.swift`：改为基于 `HIDMouse`，`currentMouse()` 保持可用。
- 设置页「按键识别」：设备选择（多设备时）、硬件信息 2×3、实时按键状态 + 左/右/中/4…8 键高亮、手动适配。
  未授权辅助功能（tap 未运行）时退回窗口内 `NSEvent` 本地监听并提示。

**自检**：`SelfTest+HID.swift` 的 `hid:` 前缀断言（按键名、事件解码、广播开关、掩码、侧键放行、
侧键/中键组合吞噬与动作、属性解析、去重排序、手动适配、PrefModel 状态、硬件只读调用）。

**已知风险**：引擎的 `downButtons` 若丢失某个 up（如 tap 被系统临时禁用），下一次单击会被当成组合手势吞掉；
键越多越可能遇到。建议引擎在 `buttonDown` 时用 `CGEventSource.buttonState(.combinedSessionState, button:)`
清理已松开的残留键（属于 GestureEngine，未改）。
