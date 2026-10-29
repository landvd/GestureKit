# 模块 04 · 鼠标手势识别

> ⚠️ **重要修正（逆向实测）**：原版的 `<glyph>Of<N>Key` 手势是
> **按住 N 个鼠标键用鼠标"画形状"**，用 DTW 与字形模板比对，**得分 > 85** 才触发；
> 不是"8 方向拖拽"，也不是"按键组合"。
> 本文件保留"方向/状态机"作为**简化实现**参考；精确算法见
> `../ALGORITHMS_RECOVERED.md`（含评分公式、30pt 门限、DTW 结构）。

## 职责
把 `InputEvent`（按键 down/up、drag、keyDown、scroll）识别成
`GestureID + Modifier`，交给规则层。**不**执行动作。

## 数据结构
```swift
struct MouseRecognizer {
    // 按下集合与时间
    var down: [(button: Int, time: TimeInterval, point: CGPoint)] = []
    var startPoint: CGPoint = .zero
    var startTime: TimeInterval = 0
    var maxDistance: CGFloat = 0
    var lastPoint: CGPoint = .zero
    var fired = false              // 本次 chord 已消费
    var swallow: Set<Int> = []     // 需要吞 up 的按键
    var keyFired: String?
    var pressTimer: Timer?
}
```

## 状态机
```
Idle
 ├─ 单键 down ───────────────► OneDown（起计时，等 0.5s 判"按住"）
 │     ├─ 0.5s 到 ──────────► fire "\(button)KeyDownning"，转 Pressed
 │     └─ up（未超时、没位移）► fire "\(button)Click"（可选）
 ├─ 第二个键 down（多键）───► Chord（记录起点，开始吞）
 │     ├─ drag：累计位移，超阈值判方向
 │     ├─ keyDown：命中字母规则 → fire "key.<char>"，吞键
 │     ├─ 任一键 up ────────► 结算方向 → fire "<dir>Of<N>Key" → Drain
 │     └─ 全部 up 但没动 ───► fire "ClickOf<N>Key"（可选）
 └─ Drain：剩余键 up 全部吞掉 → Idle
```

## 方向判定
```swift
func direction(from a: CGPoint, to b: CGPoint, minDistance: CGFloat) -> String? {
    let dx = b.x - a.x, dy = b.y - a.y          // 左上原点，y 向下
    guard hypot(dx, dy) >= minDistance else { return nil }
    if abs(dx) > 2 * abs(dy) { return dx < 0 ? "left" : "right" }
    if abs(dy) > 2 * abs(dx) { return dy < 0 ? "up"   : "down"  }
    if dx < 0 { return dy < 0 ? "upLeft" : "downLeft" }
    return dy < 0 ? "upRight" : "downRight"
}
```
阈值：原版实测 `distanceOfIgnoreDragged = 8px`（起始忽略），方向触发距离建议 24pt；斜向用 2:1 比例而不是 45°，
避免手抖误判。

## 组合键（双键/多键）
- `N = 当前同时按下的键数`（2..8），手势 id = `"\(dir)Of\(N)Key"`。
- 只支持左+右（2 键）时也要兼容：N 可变但规则里通常只配 2。
- 按下的顺序无关（左先/右先都算）。

## 按住（Downning）
- 单键按住 500ms 触发一次；期间有位移 → 取消按住判定，转入拖拽。
- 触发后抬手不重复触发。
- 多键同时按住 → 需要定义优先级（建议：先达到 0.5s 的键优先，其余忽略）。

## 连击（Click / DoubleClick）
- `mouseEventClickState` 直接给连击数；若走 HID 则自己用 300ms 窗口计。
- 只有"没有位移"才算点击。

## 修饰键维度
- 每次事件都读 `flags`，归一化成字符串（`-` / `⌘⌥` / `⌃⇧` 按固定顺序）。
- 修饰键只作为规则匹配的附加维度，不改变手势本身。

## 吞事件规则
| 场景 | 是否吞 |
|---|---|
| chord 中第二个键 down | 吞（避免右键菜单） |
| chord 中的 drag | 吞（避免拖选） |
| chord 结算后的剩余 up | 吞（避免残留点击） |
| chord 中命中字母规则的 keyDown | 吞 |
| 其它 | 放行 |

## 边界与坑
1. 用户可能先右键再左键 → 两种顺序都要进 chord。
2. chord 中又按下第三键 → 仍按 N=3 处理，方向结算用 `Of3Key`。
3. 系统"三指拖移"、BetterAndBetter 等同时监听会抢事件 → 文档提示二选一。
4. 拖拽期间系统可能触发窗口拖动 → 吞 drag 可以避免。
5. 触控板点击也会产生鼠标事件 → 需要按设备来源过滤（见 03）。

## 测试点
- 8 个方向各一条合成事件 → 断言 gesture id
- 双键 + 字母（a/v/t/f/shift+,）→ 断言并确认键被吞
- 0.4s 按住不触发、0.6s 触发
- 双键但没位移 → 不触发方向动作
- 先右后左的顺序同样触发
