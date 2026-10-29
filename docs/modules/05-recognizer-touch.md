# 模块 05 · 触控板 / 妙控鼠标手势识别

## 职责
把多指帧序列识别成 `NFinger_*` 手势；含分区、方向、按压、捏合、边缘、指尖。

## 数据结构
```swift
struct TouchState {
    var count = 0
    var startCentroid: CGPoint = .zero
    var startSpread: CGFloat = 0
    var startTime: TimeInterval = 0
    var lastCentroid: CGPoint = .zero
    var maxMove: CGFloat = 0
    var fired = false
    var maxPressure: Float = 0
    var startZone: Zone = .center
    var startEdge: Edge? = nil
}
```

## 手势判定表

| 手势 | 条件 |
|---|---|
| `NFinger_Tap` | 接触 < 250ms、位移 < 8pt、压力未超阈值 |
| `NFinger_Click` | 压力突增（物理按压）或 `NSEvent.clickCount` |
| `NFinger_ForceClick` | 压力 > forceThreshold（需硬件支持） |
| `NFinger_DoubleTap` | 两次 Tap 间隔 < 300ms |
| `NFinger_Swipe_<Dir>` | 位移 > 40pt 且方向占优（\|dx\|>1.5\|dy\| 或反之） |
| `NFinger_Swipe_<Dir>_From <Edge>` | 同上 + 起点在边缘带（原版实测 3%） |
| `NFinger_Pinch_In/Out` | spread 变化率 > 15% |
| `NFinger_TipTap_<Zone>` | 接触面积 < 阈值（指尖） + 区域 |
| `NFinger_TipSwipe_*` | 指尖 + 位移 |
| `NFinger_LeftFinger_Swipe*` | 取最左手指的位移方向 |
| `NFinger_RightFinger_Swipe*` | 取最右手指 |
| `TrackpadThreeFingerDrag` | 3 指整体平移 > 阈值 → 合成拖拽 |

## 区域划分
- 归一化坐标 0..1（左下原点）。
- 9 宫格：x 分 1/3、y 分 1/3 → `Top_Left / Top_Middle / Top_Right / Left / Middle / Right / Bottom_Left / Bottom_Middle / Bottom_Right`。
- 额外边：`Left / Right / Top / Bottom`（宽 10%）。
- 指尖 vs 指腹：`size < 0.6 * medianSize` 视为指尖。

## 三指模拟中键（妙控鼠标/触控板）
```
检测：count == 3 且压力突增（或物理点击）
动作：post otherMouseDown(button 2)
      后续帧的质心位移 → post otherMouseDragged
      抬起 → post otherMouseUp
```
注意：要吞掉原始 3 指事件，避免同时触发系统的三指手势。

## 与系统手势冲突
| 系统手势 | 冲突 | 处理 |
|---|---|---|
| 三指拖移 | 抢 3 指平移 | 检测到就提示关闭系统项 |
| 双指滚动 | 与 Swipe 混淆 | Swipe 要求位移快且大；滚动有 phase |
| 通知中心/调度中心 | 边缘滑入 | 起点在边缘才判，普通滑动不抢 |

## 时序细节
- 用时间戳（秒）而不是帧号。
- 帧率 60/120Hz 都可能，阈值按"距离"不按"帧数"。
- 手指数量在过程中变化（2→3）→ 以"起手数量"为准，变化则取消当前手势。

## 测试点
- 1..5 指 Tap / Swipe 各一条
- 边缘起手 vs 中心起手
- 捏合 in/out
- 三指中键合成后，拖拽能移动光标
- 快速 Tap 不误判 Swipe；慢速小位移不误判 Tap


## 实现（2026-10-28）
`Sources/TouchRecognizer.swift`（纯逻辑，`--selftest` 用合成帧覆盖 17 种情况）。

| 判定 | 规则 |
|---|---|
| 会话 | 第一指落下开始，全部离开结束；一次会话最多一个手势 |
| 指数 | 起手 0.3s 内增加手指 = 错落落指，重设基线；之后增加 = 取消 |
| 滑动 | 质心位移 ≥ 0.10（2 指）/ 0.03（3–5 指），主轴 > 1.5 × 副轴；1 指不做滑动 |
| 边缘 | 起手任一指距对应边 ≤ 0.03 → `.from<Edge>`；无规则回退到普通滑动 |
| 捏合 | 扩散比 < 0.6 → pinchIn，> 1.6 → pinchOut；扩散变化须大于质心位移；起始扩散 ≥ 0.03 |
| 轻点 | 抬起时：时长 ≤ 0.25s（1 指）/ 0.35s（多指），位移 ≤ 0.02 / 0.05；1 指附九宫格区 |

未做：TipTap、单指跟随（LeftFinger_Swipe）、物理按压 Click、DoubleTap、手掌过滤。


## 实现（2026-10-28）：妙控鼠标
- 设备层按 family id（112/113）把设备标为妙控鼠标，启动时把每个设备的 family 写日志，便于真机核对。
- 轻点/滑动复用 `TouchRecognizer(prefix: "magicMouse")`，id 为 `magicMouse.*`，阈值与触控板相同。
- 点按：真实 left/rightMouseDown 到来时，若 0.25s 内妙控鼠标上有手指（且没有其它键按着）→
  候选 `magicMouse.1f.click.<区>`（单指）→ `magicMouse.<N>f.click`；命中规则才吞掉这次 down，
  对应的 dragged/up 也吞（在暂停判断之前处理，不会丢 up）。无论命中与否都取消本次会话的轻点。
- 区域方向（y 轴朝前/朝后）未在真机校准。


## 实现（2026-10-28）：扩展手势
识别在 `TouchRecognizer`（纯逻辑，帧时间戳判定）；引擎只做派发/吞噬。`--selftest` 的 `touch+:` 组（`Sources/SelfTest+TouchExtra.swift`，26 条）覆盖。

| 手势 | id | 规则 |
|---|---|---|
| 触控板物理点按 | `trackpad.1f.click.<区>` → `trackpad.<N>f.click` | 真实 left/rightMouseDown 到来时，触控板最近一帧 < 0.25s 且**手指仍在按着、没有手指开始离开**（`isPressing`）；没有其它键按着。命中规则才吞掉 down 及对应 dragged/up（`swallowedButtons`），否则放行；无论命中与否取消本次会话的轻点/滑动 |
| 双击 | `<prefix>.<N>f.doubleTap` | 第二次同指数轻点在第一次抬起后 ≤ 0.3s 落下、两次质心距离 ≤ 0.1。**仅当该指数有 doubleTap 规则**才把单击压后（计时器 0.32s，`GestureEngine.touchTimer` 可注入）；没有规则时单击照旧立即触发。双击命中后不再触发单击；第二次不是轻点（滑动等）时先补发单击 |
| TipTap | `trackpad.2f.tipTap.left/right` | 单指已按住 ≥ 0.3s（落指整合窗口之后），另一指落下并在 0.3s 内抬起、自身位移 ≤ 0.03；按住的手指位移 ≤ 0.02（RE 0.01，放宽以容忍手抖）；按轻点指相对按住指的 x 判左右。按住指不抬可连续 TipTap。仅触控板 |
| 单指跟随滑动 | `trackpad.<N>f.leftFingerSwipe<Dir>` / `rightFingerSwipe<Dir>`（N=2…4） | 起手最左/最右那根手指位移 ≥ 0.15（2 指）/ 0.18（3、4 指）、主轴 > 1.5×副轴，其余手指都 ≤ 0.03。**仅当该指数有跟随规则**才启用；单指刚开始单独移动（> 0.03）且朝向有规则时压住普通滑动/捏合，朝向无规则或斜向则立刻放弃，普通手势照旧 |

手指身份：帧里没有手指 id，按上一帧最近邻贪心匹配（`TouchRecognizer.match`）。

**轻点 vs 物理点按的取舍**：「轻点来点按」的合成 click 在手指离开时才发出，此时最近一帧已是 0 指（或处于抬起中，指数减少），所以不算物理点按；物理按压时手指仍在。残余风险：若合成 click 先于抬起帧到达主线程（两路异步），会被当成点按——只在用户配置了对应 click 规则时才有影响。没有用接触时长下限，因为快速物理点按的接触也可能 < 0.25s。

未做：Near/Far TipTap（两指距离 0.5 分界）、3 指 TipTap、ForceClick、手掌过滤、三指拖移。


## 实现（2026-10-28）：Force Click / TipTap 远近 / 三指 TipTap / 手掌过滤
`touch+:` 组新增 26 条断言（`Sources/SelfTest+TouchExtra.swift`）。

| 手势 | id | 规则 |
|---|---|---|
| Force Click | `trackpad.1f.forceClick.<区>` → `trackpad.<N>f.forceClick` | 公开 API：`AppDelegate` 装 `NSEvent.addGlobalMonitorForEvents(matching: .pressure)`，`event.stage` 交给 `GestureEngine.handleForceClick(stage:)`；**上升沿到 stage 2** 算一次（stage 回 0 或手指全部离开才重新武装）。指数/区取 0.5s 内最近的触控板帧；无触控数据时按 `trackpad.1f.forceClick`。命中规则才执行；同时取消本次会话的轻点/滑动。全局监听**无法吞掉**系统的「用力点按查询」，编辑器里有提示。仅触控板 |
| 与普通点按的先后 | — | stage 1 的 mouseDown 先到。若该次按压的点按候选有规则，**且** Force Click 候选也有规则：吞掉 down，点按规则压到 mouseUp 再执行；期间出现 stage 2 则丢弃（只触发 Force Click）。没有 Force Click 规则时点按照旧在 mouseDown 立即执行。没有点按规则时 down 放行（系统点击照常） |
| TipTap 远近 | `trackpad.2f.tipTap.<left\|right>.<near\|far>` → `trackpad.2f.tipTap.<left\|right>` | 判定同 TipTap；按住指与轻点指（落下时）的归一化距离 < 0.5 → near，≥ 0.5 → far（RE 字面量 0.5）。无具体规则回退通用 id |
| 三指 TipTap | `trackpad.3f.tipTap.left\|middle\|right` | 两指已按住（落指整合窗口 0.3s 之后、未触发手势），第三指落下并在 0.3s 内抬起、自身位移 ≤ 0.03，两根按住指各自位移 ≤ 0.02；轻点指 x 在两指左侧/之间/右侧 → left/middle/right。按住不抬可连续。仅触控板 |
| 手掌过滤 | — | `TouchFrame.sizes`（MultitouchSupport finger `size`，偏移 48，可选，默认空）。接触 size ≥ 3.5，或 size ≥ 2.0 且 > 2.5 × 本帧下中位数 → 视为手掌丢掉（`TouchRecognizer.dropPalms`，引擎入口与识别器入口都过一遍，结果不带 sizes 故幂等）。点按/Force Click 的指数也用过滤后的帧。sizes 为空或与点数不符时不过滤，行为与之前一致 |

门限是按「指尖 ≈ 0.5–1.5」的常见经验值定的，**未在真机校准**：若手掌漏过或指腹被误删，调 `palmAbsoluteSize` / `palmRelativeMinSize` / `palmRelativeRatio`。相对门限带绝对下限 2.0，是因为刚落下的手指 size 很小，会把同帧中位数拉低。

未做：三指拖移；`.pressure` 全局监听在真机上能否收到（需辅助功能权限）未验证。
