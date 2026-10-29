# 模块 11 · 平滑滚轮

## 职责
拦截原始 `scrollWheel`，用插值动画替代系统的"一格一跳"，让滚动更顺滑。
**不修改系统设置**，只在本进程内改写事件。

## 原理
```
原始事件 delta D  →  丢弃  →  自己按 120Hz 发送一系列小 delta
                   （总和 = D × speed）
```

## 数据结构
```swift
struct Smoother {
    var pendingY: CGFloat = 0      // 还没发完的像素
    var pendingX: CGFloat = 0
    var timer: DispatchSourceTimer?
    var speed: CGFloat = 1.0       // 0.5 ~ 2.0
    var enabled = true
}
```

## 算法
```swift
func onScroll(_ e: CGEvent) -> CGEvent? {
    guard enabled, !modifierPaused else { return e }
    let dy = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let dx = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    pendingY += CGFloat(dy) * speed
    pendingX += CGFloat(dx) * speed
    ensureTimer()                       // 120Hz
    return nil                          // 吞掉原始事件
}

func tick() {
    let stepY = pendingY * 0.35         // 指数衰减
    let stepX = pendingX * 0.35
    if abs(stepY) < 0.5 && abs(stepX) < 0.5 {
        pendingY = 0; pendingX = 0; stopTimer(); return
    }
    postScroll(dx: stepX, dy: stepY, phase: .changed)
    pendingY -= stepY; pendingX -= stepX
}
```

## 细节
- 必须用 `pointDelta`（像素）而不是 `lineDelta`。
- `phase`：首次 `.began`，中间 `.changed`，结束 `.ended`（可选，某些 App 依赖）。
- 惯性：如果原事件带 `momentumPhase`，可透传或统一由自己接管。
- 修饰键暂停：按住 ⌃/⌥/⌘ 时直接放行原始事件（`disableSmoothScrollOfHoldingModifierkey`）。
- 按 App 单独配置：`SmoothScrollIndividualSetting[bundleID]`；未配置用全局。
- 水平/垂直反转：`reverseMouseScrollX/Y` 在发送前取反。
- 与 Logitech Options / Mos / LinearMouse 冲突：文档提示二选一；检测到同类进程可提示。

## 性能与稳定
- 定时器合并（leeway 1ms），避免 CPU 抖动。
- 事件风暴时限制 pending 上限（如 ±500px），防止"滚过头"。
- 睡眠/切换 App 时清空 pending。

## 测试点
- 滚一格产生多帧小 delta，总量 ≈ 原始 × speed
- 按住 ⌘ 时不平滑（原始事件直通）
- 快速连续滚动不丢步、不超调
- 关闭开关后行为与系统一致


## 实现（2026-10-28）
- `Sources/SmoothScroll.swift`，由 `GestureEngine.handle(.scrollWheel)` 调用（在边角判定之后）。
- 只接管 `scrollWheelEventIsContinuous == 0` 的离散滚轮；触控板/妙控鼠标原样放行。
- 修饰键：⌃ ⌥ ⌘ 以及 ⇧（App 用 ⇧ 做水平滚动，合成事件不带 flags）按住时放行。
- 增益 = speed / 3（3 = 与系统同距离）；每帧发送 pending × 0.35，余量 < 2px 时一次发完，总量精确守恒。
- 反向滚动清空在途量；pending 上限 ±1000px。
- 自己发出的事件 `eventSourceUserData = 0x474B5353`，引擎第一行就放行，不会二次平滑或触发边角。
- 配置 `smoothScroll`（见 PROJECT §5），设置「普通鼠标 → 平滑滚轮」各控件已接通。
