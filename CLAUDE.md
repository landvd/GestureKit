# CLAUDE.md — 给编码 Agent 的速查

## 这是什么

`GestureKit` 是一个 macOS 菜单栏鼠标手势工具（Swift + AppKit，无第三方依赖），
最初用来替代 BetterAndBetter 中用户实际在用的那部分功能，现在独立演进。

当前状态：v0.3（精简版）。保留：鼠标手势（右键或双键起手，直线/斜线/折线/字母/自定义图形）、
边角滚轮（音量/亮度，音量步长可调）、115 个预设动作、手势记录与学习、设置窗口、导入导出、中英文、权限向导、稳定签名。
**已移除，不要再加回**：窗口吸附、触控板手势、平滑滚轮/滚轮方向、妙控鼠标、键盘触发、脚本库、iCloud 同步、
学习教程/免费 Apps/问题反馈页、导入原版 `.BABPreset`、「按键识别」页（HID 设备枚举）。
`--selftest` 全绿；设置窗口改动后跑 `--ui-click-test`（真实点击每个侧栏，约 30 秒，期间别动鼠标）。

## 先读

1. **`docs/STATUS.md` — 项目状态、测试命令、待人工验证清单（先看这个）**
2. `docs/PROJECT.md` — 架构、数据流、每个文件做什么、配置格式
3. `docs/MANUAL_TEST.md` — 人工验收步骤

## 构建 / 测试 / 运行

```bash
./build.sh                 # 编译 + selftest + ad-hoc 签名（必须全绿）
./GestureKit.app/Contents/MacOS/GestureKit --prefs            # 打开设置窗口
./GestureKit.app/Contents/MacOS/GestureKit --prefs-page 边角触发
./GestureKit.app/Contents/MacOS/GestureKit --selftest
./GestureKit.app/Contents/MacOS/GestureKit --dry-run   # 动作只打日志
open -a ./GestureKit.app
```

日志：`~/Library/Application Support/GestureKit/gesturekit.log`
配置：`~/Library/Application Support/GestureKit/rules.json`

## 硬性约束

- **不要**复制、反编译粘贴原 App 的代码、nib、图标、字符串。所有实现自己写。
- **不要**联网、上报、读取用户隐私数据。
- **不要**引入第三方依赖（保持 `swiftc Sources/*.swift` 就能编译）。
- 新增手势或动作 **必须** 加 `--selftest` 断言，否则不算完成。
  断言按区域放在 `Sources/SelfTest+<区域>.swift`，在 `SelfTestSuites.swift` 注册（main.swift 只放通用断言）。
- 面向用户的文案一律 `L("中文原文")`，英文写进 `Sources/L10n.swift` 或 `L10n+<区域>.swift`
  （同一张表里不能有重复 key，否则启动崩溃；`scripts/check-l10n.sh` 由 build.sh 自动检查）。
- SwiftUI 不能用 `@State` / `@StateObject`（宏，裸 swiftc 没有宏插件），用 ObservableObject + @Published。
- 所有合成事件（按键、鼠标、滚动）必须打 `Actions.syntheticMarker`，否则会被自己的 tap 再处理。
- 动作的副作用走 `Actions.effects`（`ActionEffects` 协议），测试用记录实现，不要直接调系统 API。
- **识别**：`Recognizer.recognize`（纯函数，规则快照）决定命中哪个手势、是否命中反例、危险动作是否够把握；
  结果同时用于执行动作和写「手势记录」（`GestureHistory`，history.json，最多 200 条）。
  个人学习数据在配置里：`learnedStrokes`（正样本）/ `rejectedStrokes`（反例）。
  改识别逻辑先跑 `--perf`（合成笔画的识别率与混淆）和 `--replay-history`（用户真实笔画按当前规则重放，评价当作标准答案）。
- **线程模型**：事件 tap 跑在独立线程 `TapThread`（不是主线程）。`GestureEngine` 的状态**只在这条线程上读写**：
  主线程改配置/暂停走 `TapThread.shared.perform`（AppDelegate 的 `onEngine` / `setEngineConfig`），
  主线程用 `AppDelegate.config` 副本；轨迹经 `onChordStroke` 交给主线程，
  外部变化（屏幕布局、前台 App）经 `engineQueue` 交回；事件 tap 不监听普通鼠标移动（只要按键、拖动、滚轮、按键盘）；形状识别在 `deferWork`（后台队列）里用规则快照算，不碰引擎状态。
  测试里这些钩子默认同步。改动后跑 `--tap-isolation-test`（主线程被卡 400ms 时光标事件仍应 < 20ms）。
- **事件 tap 回调里不能有任何可能变慢的调用**：不调 NSScreen / NSWorkspace（用引擎里的缓存）、
  不做 IO、不跑 AppleScript / AX / 子进程；动作一律经 `Actions.executor` 在 `Actions.workQueue` 执行。
  改动后跑 `--perf`，真实管线用 `GK_PERF=1` 看日志（含主线程卡顿统计）。
- 测试里创建 `GestureEngine` 必须用 `makeEngine()`（它设了 `rulesetOverride`），
  否则会依赖"当前前台 App"，在别人机器上随机失败。
- 事件吞噬要保守：只有确实处于 chord 状态才 `return nil`，
  其余一律 `passUnretained`，避免把系统输入卡死。

## 代码风格

- 每个文件一个职责，新增能力优先加在对应文件，不要造 God class。
- 动作统一走 `ActionSpec`（`type` + 参数），新类型在 `Actions.perform` 里加 `case`，
  并在 `Rules.swift` 的文档注释里登记。
- 日志用 `Log.write`，不要 `print`（GUI 进程没有 stdout）。
- 面向用户的文案用中文，代码注释中英均可。

## 已知的坑

1. **TCC 与签名**：ad-hoc 签名按 cdhash 认身份，重新编译+签名后
   「辅助功能」权限会失效。用户运行过 `scripts/make-signing-cert.sh` 后 `build.sh`
   自动用固定证书签名，权限不再丢（看 build.sh 输出的「身份」行判断）。
   证书脚本会改登录钥匙串，**只能由用户本人运行**。见 `docs/PROJECT.md` 技术债 6。
2. **坐标**：`CGEvent.location` 是左上原点；`NSScreen.frame` 是左下原点。
   热区判定已经做过转换，新增屏幕相关逻辑务必检查。
3. **热区滚动**：一次物理滚动会产生几十个 `scrollWheel` 事件，
   必须累积 + 节流（已有 0.4s + 阈值 4），否则会连发动作。
4. **前台 App**：per-app 规则用 `NSWorkspace.shared.frontmostApplication`，
   在测试/无 GUI 环境可能为 nil，要有默认回退。
5. **全屏**：`AXFullScreen` 个别 App 不支持，已回退 ⌃⌘F。
6. **与 BetterAndBetter 并存**：两边都监听双键手势会双触发，文档已提示，不算 bug。

## Definition of Done（新功能）

- [ ] `./build.sh` 通过，selftest 全绿且新增了对应断言
- [ ] `--dry-run` 下能看到预期动作
- [ ] 至少人工验证 1 次（Safari/Finder/VS Code 三选二）
- [ ] 更新 `docs/STATUS.md`（能力表或待验证清单）
- [ ] 不引入新的已知崩溃（日志无异常堆栈）
