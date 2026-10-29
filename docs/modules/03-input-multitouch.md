# 模块 03 · 触控板 / 妙控鼠标多指（MultitouchSupport）

## 职责
拿到每一帧的"手指集合"（数量、坐标、接触面积、压力），供识别层做
Tap/Swipe/Pinch/边缘/指尖/绘图/三指中键。

## 两条路线

| 路线 | 能拿到 | 代价 |
|---|---|---|
| A. `NSEvent` 手势 | swipe 方向、magnify、rotate | 无手指坐标/数量，做不了 Tap 分区、绘图 |
| B. `MultitouchSupport.framework`（私有） | 每指 x/y/size/pressure | 私有 API，系统升级可能失效；App Store 会被拒 |

复刻建议：B 为主，A 作为 B 失败时的降级。

## 私有 API 骨架
```swift
typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
typealias MTRegisterFrameFn = @convention(c)
    (OpaquePointer, @convention(c) (OpaquePointer, UnsafePointer<Finger>, Int32, Double, Int32) -> Void) -> Void
typealias MTStartFn = @convention(c) (OpaquePointer, Int32) -> Void

struct Finger {            // 字段随系统版本略有差异，需运行时校验
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var foo3: Int32
    var foo4: Int32
    var normalized: (Float, Float)   // 0..1
    var size: Float
    var pressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mm: (Float, Float)
    var density: Float
}
```
加载：
```swift
let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
let createList = dlsym(h, "MTDeviceCreateList")
let register   = dlsym(h, "MTRegisterContactFrameCallback")
let start      = dlsym(h, "MTDeviceStart")
```
遍历设备 → 注册回调 → `MTDeviceStart(dev, 0)`。

## 帧处理
```swift
func onFrame(_ fingers: [Finger], _ timestamp: Double) {
    let touches = fingers.filter { $0.state != 7 }         // 7 = 离开
    let centroid = touches.reduce(.zero) { $0 + $1.point } / CGFloat(touches.count)
    let size = touches.map(\.size).reduce(0,+) / Float(touches.count)
    let spread = touches.map { distance($0.point, centroid) }.reduce(0,+) / CGFloat(touches.count)
    recognizer.feed(.init(count: touches.count, centroid: centroid,
                          spread: spread, size: size,
                          points: touches.map(\.point), time: timestamp))
}
```

## 坐标系
- 归一化 0..1（左下原点），转屏幕坐标：`x * trackpadWidth`、`y * trackpadHeight`。
- 分区判定用归一化坐标，避免分辨率差异。

## 线程
回调在专用线程；只做"拷贝成值类型"，然后 `DispatchQueue.main.async` 或投递到识别队列。
不要在该线程做 UI / AX / 文件 IO。

## 降级
- `dlopen` 失败或设备列表为空 → 用 `NSEvent.addGlobalMonitorForEvents([.swipe,.magnify,.rotate])`。
- 降级后功能子集：Swipe / Pinch / Rotate；Tap 分区、指尖、绘图不可用 → 设置界面置灰。

## 边界
- 手指抬起顺序、帧率抖动（120Hz vs 60Hz）→ 用时间戳而不是帧数。
- 手掌误触：面积过大（> 阈值）忽略。
- 三指拖拽会与系统"三指拖移"冲突 → 检测到就提示用户关闭系统项。

## 测试点
- 1..5 指分别产生正确 count
- 快速 Tap（<250ms）被判为 Tap 而不是 Swipe
- 边缘起手被判 `*_From <Edge>`
- 设备断开后回调停止、不崩溃


## 实现（2026-10-28）
- `Sources/Multitouch.swift`：dlopen + `MTDeviceCreateList` / `MTRegisterContactFrameCallback` / `MTDeviceStart`。
- Finger 结构按 96 字节步长、固定偏移读取（state@20、normalized x/y@32/36），只取 state 3/4（接触中）。
- 回调线程只拷贝点坐标，`DispatchQueue.main.async` 交给 `GestureEngine.handleTouchFrame(_:device:)`。
- 每个设备一个识别器；Magic Mouse（family 112/113）暂时跳过。
- 睡眠唤醒后重新注册（`NSWorkspace.didWakeNotification`）。
- 不可用时只记日志，NSEvent.swipe 降级路径保持不变。
