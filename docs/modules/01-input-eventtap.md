# 模块 01 · 全局事件采集（CGEventTap）

## 职责
把系统级鼠标/键盘/滚轮事件变成内部 `InputEvent`，并在"手势占用"期间抑制原始事件。
**不**做手势判定（交给识别层）。

## 依赖
- `CoreGraphics`（CGEvent、CGEventTap）
- 权限：辅助功能（Accessibility）或输入监控（Input Monitoring）

## 生命周期
```
start()  → 创建 tap → 加入 main RunLoop(.commonModes) → enable
stop()   → disable → 移除 source → 释放
系统回调 tapDisabledByTimeout/UserInput → 立即 re-enable，并计数；>3 次/分钟 降级为 listenOnly 并提示
```

## 创建参数
```swift
let mask: CGEventMask =
  (1 << .leftMouseDown.rawValue)  | (1 << .leftMouseUp.rawValue)   |
  (1 << .rightMouseDown.rawValue) | (1 << .rightMouseUp.rawValue)  |
  (1 << .otherMouseDown.rawValue) | (1 << .otherMouseUp.rawValue)  |
  (1 << .leftMouseDragged.rawValue) | (1 << .rightMouseDragged.rawValue) |
  (1 << .otherMouseDragged.rawValue) |
  (1 << .scrollWheel.rawValue)    | (1 << .keyDown.rawValue) |
  (1 << .keyUp.rawValue)          | (1 << .flagsChanged.rawValue)

CGEvent.tapCreate(tap: .cgSessionEventTap,
                  place: .headInsertEventTap,
                  options: .defaultTap,        // 必须 defaultTap 才能 return nil 吞事件
                  eventsOfInterest: mask,
                  callback: cb, userInfo: ctx)
```
- `.cgSessionEventTap`：当前登录会话，够用且比 `.cghidEventTap` 干扰小。
- `.headInsertEventTap`：先于其它 tap 看到事件。
- 若要"连别的 App 也看不到"，才用 `.cghidEventTap`（更危险，慎用）。

## 事件 → InputEvent 映射

| CGEvent 字段 | 含义 | 备注 |
|---|---|---|
| `type` | 事件类型 | 见掩码 |
| `.mouseEventButtonNumber` | 0=左 1=右 2=中 3..7=4..8 键 | `otherMouse*` 才有 3+ |
| `.mouseEventClickState` | 连击次数 | 双击=2 |
| `.location` | 光标坐标 | **左上原点**，与 NSScreen 相反 |
| `.flags` | 修饰键 | `.maskCommand` 等 |
| `.keyboardEventKeycode` | 虚拟键码 | 与键盘布局相关 |
| `.scrollWheelEventPointDeltaAxis1/2` | 像素增量 | 优先用 point（不是 line） |
| `.scrollWheelEventScrollPhase` | 1=began 2=changed 4=ended | 判手势边界 |
| `.scrollWheelEventMomentumPhase` | 惯性阶段 | 平滑滚动要用 |
| `.mouseEventPressure` | 压力 | ForceClick |

## 抑制（吞事件）策略

```
状态机：Idle → Chord → Drain → Idle

Idle:   全部放行
Chord:  第二个鼠标键 down/up、chord 中的 drag、被规则消费的字母键 → 吞
Drain:  chord 结束但还有键未抬起 → 继续吞这些键的 up，直到 down 集合为空
```
原则：
1. 只有确实处于手势状态才吞；任何异常状态立即回 Idle 并放行。
2. 吞键前先确认"这条规则存在"，避免用户按键失效。
3. 每次吞事件都记 debug 日志（类型/键号），便于排查"鼠标失灵"。

## 错误与边界
- tap 创建失败：多半没权限 → 提示 + 5s 重试（不要弹模态框阻塞）。
- 回调内耗时 > 1ms 会被系统警告甚至禁用 tap → 重活异步派发。
- 睡眠唤醒后 tap 可能失效 → 监听 `NSWorkspace.didWakeNotification` 重建。
- 多用户快速切换 → `sessionDidResignActive` 时停，`didBecomeActive` 时重启。

## 性能预算
| 项 | 预算 |
|---|---|
| 单事件处理 | < 200µs |
| 每秒事件上限 | 5,000（超了降采样） |
| 日志 | 生产环境只记 WARN+ |

## 测试点
- 合成 8 种鼠标事件 → 断言 InputEvent 字段解析正确
- chord 期间右键不产生菜单（用合成事件 + 前台 App 断言）
- tap 被禁用后能自动恢复
- 权限撤销后 stop 不崩溃

## 代码骨架
```swift
final class EventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    weak var sink: InputSink?

    func start() -> Bool {
        guard let tap = CGEvent.tapCreate(...) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        return sink?.consume(type, e) ?? Unmanaged.passUnretained(e)
    }
}
```
