# 模块 06 · 屏幕边角 + 绘图手势

## A. 屏幕边角

### 职责
鼠标在屏幕角落/边缘时，用滚轮触发动作。

### 几何
```swift
struct CornerZone {
    let name: String            // topLeft/topRight/bottomLeft/bottomRight
    let rect: CGRect            // CG 坐标（左上原点）
}
// 以主屏高度做 NSScreen(左下原点) → CG 的转换
let mainH = NSScreen.screens.first!.frame.height
func cgRect(_ s: NSScreen) -> CGRect {
    CGRect(x: s.frame.minX, y: mainH - s.frame.maxY,
           width: s.frame.width, height: s.frame.height)
}
```
- 角：`size`（默认 40pt）正方形。
- 边：12 条（上左/上中/上右/右上/右中/右下/下右/下中/下左/左下/左中/左上），
  宽度可配置（`边缘宽度`）。

### 触发
```swift
func onScroll(delta: CGFloat, at p: CGPoint) {
    guard let zone = zone(at: p) else { accumulator = 0; return }
    accumulator += delta
    guard abs(accumulator) >= 4, now - lastFire > 0.4 else { return }
    fire("corner.\(zone).\(accumulator > 0 ? "up" : "down")")
    accumulator = 0; lastFire = now
}
```
- 一次物理滚动会产生几十个事件 → **必须**累积 + 节流（否则连发几十次）。
- 多屏：遍历所有屏幕的 CG rect，取包含点的那个。
- 滚动方向：`pointDeltaAxis1 > 0` 记为 up（自然滚动可在设置里反转）。

### 测试点
- 角内滚动 20 次事件 → 只触发 1 次
- 离开角落后再回来 → 重新计数
- 多屏：副屏角落也能触发

---

## B. 绘图手势

### 职责
在触控板/鼠标上画出轨迹，与预设模板匹配后执行动作。

### 采样
```swift
struct Stroke {
    var points: [CGPoint] = []
    var angles: [CGFloat] = []
    var duration: TimeInterval = 0
}
// 每 8ms 采一个点；距离 < 2pt 的点丢弃（去抖）
```

### 预处理
1. 去重、平滑（3 点滑动平均）。
2. 按包围盒归一化到 0..1。
3. 等距重采样到 N=32 点。
4. 计算相邻段角度（弧度），得到 31 个角度。

### 匹配（原版实测）

```swift
// 1) 轨迹相对首点需超过 30pt，否则 0 分
// 2) 预计算每点的累计弧长
// 3) 弧长参数化 + 角度加权的 DTW 得到距离 d
// 4) score = max(0, 1 - 2.5*d) * 100
// 5) 命中条件：score > 85   （即 d < 0.06）
```
原版距离矩阵初值 0.2，直接返回右下角（不做长度归一化）。
完整反编译见 `../ALGORITHMS_RECOVERED.md`。
- 允许旋转：比较角度差时取 `min(|d|, 2π-|d|)`。
- 起点不同：先对齐起点（平移到原点）。
- 方向相反（画反了）默认不命中，可在设置里允许。

### 触发位置
- 鼠标绘图：按住指定键（右键/中键）时记录轨迹，松开时匹配。
- 触控板绘图：单指长按或拇指压底边 + 另一指绘制。
- 显示轨迹：透明覆盖窗（`NSWindow` level 高、忽略鼠标事件）实时画线。

### 性能
- 模板数量 × 32 点，匹配 < 1ms；模板 > 50 个时建 KD-Tree 或先按包围盒粗筛。

### 测试点
- 同一轨迹录制两次 → 分数 > 0.95
- 反向绘制 → 分数低
- 不同大小/位置 → 归一化后仍命中
- 模板为空时不崩溃
