# 模块 14 · 权限与生命周期

## 需要的权限

| 权限 | 用途 | 检测 | 申请 |
|---|---|---|---|
| 辅助功能 | AX 窗口操作、事件 tap（部分场景） | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions([prompt: true])` |
| 输入监控 | 读取 HID / 全局键盘 | `IOHIDCheckAccess` / tap 创建失败 | 系统设置手动 |
| 屏幕录制 | 截图 | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` |
| 完全磁盘访问 | 读其它 App 数据（可选） | 访问 `~/Library/Mail` 试探 | 系统设置手动 |
| 自动化 | AppleScript 控制其它 App | 执行时报错 -1743 | 首次执行自动弹 |

## 权限向导
```
启动 → 逐项检测
  ├─ 全部通过 → 正常运行
  └─ 缺失 → 显示向导页（图文步骤 + "去授权"按钮 + 轮询）
        每 1s 重新检测，授权后自动进入下一步
```
要点：
- 不要用模态 alert 阻塞（用户去系统设置时看不见）。
- 说明"已授权但仍无效时，请删除后重新添加"（ad-hoc 签名常见）。

## 启动流程
```
1. 单实例检查（NSRunningApplication / 文件锁）
2. 加载配置（失败用默认）
3. 权限检测 → 缺失则向导
4. 创建 event tap（失败 → 5s 重试）
5. 启动多指/ HID
6. 菜单栏图标
7. 注册登录项（若开启）
```

## 登录项
```swift
try SMAppService.mainApp.register()     // macOS 13+
// 状态：.enabled / .requiresApproval / .notRegistered
```
- `requiresApproval` 时提示用户去"系统设置 → 通用 → 登录项"允许。

## 自我安装（LetsMove）
- 首次运行若不在 `/Applications`，提示"移动到应用程序文件夹"。
- 复制自身 → 校验签名/哈希 → 重启新路径 → 删除旧副本。

## 异常处理
- tap 被系统禁用 → 自动重开，连续失败降级。
- 睡眠唤醒 → 重建 tap / 多指设备。
- 用户切换 → 会话变化时停/启。
- 崩溃 → 写 `logs/crash.log`，下次启动提示"上次异常退出"。

## 测试点
- 撤销权限后 App 不崩溃、给出引导
- 授权后无需重启即恢复
- 移到 /Applications 后登录项正常

## 实现（2026-10-28，P2-14 权限向导）

文件：`Sources/PermissionWizard.swift`（新）、`Sources/AppDelegate.swift`、`Sources/SelfTest+Permissions.swift`。

- `PermissionPolicy`（纯逻辑）：`onTapFailure(trusted:alreadyPrompted:wizardAutoShown:)`
  → 未授权时首次自动打开向导、系统提示整个进程最多一次、始终保留 5s 重试；
  已授权但 tap 仍失败只重试。`menu(trusted:)` → 已授权提示 / 未授权打开向导。
- `PermissionWizardLogic`（纯状态机）：`waiting → granted → done`。
  `step(trusted:now:)` 返回副作用：`startTap` 整个向导生命周期最多一次；
  授权后 `closeDelay`（1.5s）发一次 `close`；`done` 后无副作用；授权后被撤销回到 `waiting`。
  `autoClose=false` 用于调试参数。
- `PermissionWizardModel`（ObservableObject）：注入 `trustProvider`（默认 `AXIsProcessTrusted`）
  与 `clock`（默认 `systemUptime`），`Timer` 每 1s `tick()`；按钮动作 `openSettings` /
  `revealApp` 也可注入。只用 `x-apple.systempreferences:...Privacy_Accessibility` URL 打开设置页，
  `NSWorkspace.activateFileViewerSelecting` 在访达中显示 App 包，不改任何设置。
- 界面：SwiftUI + NSHostingView，复用 `UI` 配色与卡片样式；卡片「为什么需要」「授权步骤」
  （含「−」删除旧条目再「+」添加 /Applications/GestureKit.app 的说明）、可选「自动化（AppleScript）」、
  实时状态行（⌛ 等待 N 秒 / ✓ 已授权，约 1.5s 后自动关闭）。图形只用 SF Symbols 与简单形状。
- AppDelegate：tap 创建失败 → `tapFailed()` 按策略打开向导 + 一次系统提示 + 单个 5s 重试计时器
  （已存在不重建）。重试计时器与向导授权回调都走唯一入口 `tryStartTap()`
  （`tap.isRunning` 时不重复 start），成功后停计时器、恢复「◈」、重建菜单。
  去掉了启动末尾重复的 `PromptForAccessibilityIfNeeded()`。
- 调试：`--permission-wizard` 启动后直接打开向导且不自动关闭。

自检：`permissionChecks()` 16 条（`perm: ...`），不创建窗口、不弹提示、不打开设置、不写日志。
