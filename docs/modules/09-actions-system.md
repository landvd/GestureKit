# 模块 09 · 系统动作（音量/亮度/媒体键/锁屏/睡眠…）

## 音量
```swift
// 方案 A：AppleScript（简单，~80ms）
set volume output volume (max(0, min(100, (output volume of (get volume settings)) + d)))

// 方案 B：CoreAudio（快，~5ms）
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &value)
```
设置界面的"静音/最大/中间"用同一接口。

## 屏幕亮度
- 内置屏：`DisplayServices` 私有
  ```swift
  dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
  DisplayServicesGetBrightness(displayID, &v)
  DisplayServicesSetBrightness(displayID, v ± delta)
  ```
- 外接屏：DDC/CI
  ```swift
  // IOAVServiceCreateWithService → IOAVServiceWriteI2C(service, 0x37, 0x51, &data, len)
  // VCP 0x10 = brightness
  ```
  失败则回退到"合成亮度键"。

## 键盘背光
```swift
// NX_KEYTYPE_BRIGHTNESS_UP/DOWN（与屏幕亮度键不同）
sendSystemKey(NX_KEYTYPE_BRIGHTNESS_UP)   // 0x03? 以实际常量为准
```
"最大/最小/中间"用循环 + 读回值逼近，或直接调用私有 `KBUpdateBacklight`。

## 媒体键
```swift
NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_NEXT = 17, NX_KEYTYPE_PREVIOUS = 18
// NSEvent.otherEvent(.systemDefined, subtype: 8, data1: (key << 16) | 0xA/0xB)
```

## 锁屏 / 睡眠 / 重启 / 退出
| 动作 | 实现 |
|---|---|
| 锁屏 | `SACLockScreenImmediate()`（dlsym SecurityAgent 私有） |
| 睡眠 | `IOPMSleepSystem(IOPMConnectionCreate(...))` |
| 重启 | `NSAppleScript("tell app \\"System Events\\" to restart")` |
| 强制退出 | 合成 ⌥⌘⎋ 或 `NSRunningApplication.forceTerminate()` |
| 退出 App | `NSRunningApplication.terminate()` |

## 废纸篓 / 桌面 / Dock
| 动作 | 实现 |
|---|---|
| 清空废纸篓 | 遍历 `~/.Trash` + `FileManager.removeItem`（可选确认） |
| 显示/隐藏桌面文件 | `chflags hidden/nohidden ~/Desktop/*` |
| 显示/隐藏 Dock | `defaults write com.apple.dock autohide -bool` + `killall Dock` |
| 显示桌面 | 合成 F11 或 Mission Control 快捷键 |
| Mission Control / Launchpad | `open -a "Mission Control"` / `open -a Launchpad` |
| 下/上一个桌面 | 合成 ⌃← / ⌃→ |

## 截图
```bash
/usr/sbin/screencapture -i  ~/Desktop/shot.png   # 区域
/usr/sbin/screencapture -w  ~/Desktop/win.png    # 窗口
/usr/sbin/screencapture -W  ...                  # 交互选窗口
```
滚动截图需要额外拼接（多帧 + 图像匹配），可后置。

## 权限依赖
- 锁屏/睡眠：无特殊权限
- 亮度（DisplayServices/DDC）：无
- 截图：屏幕录制权限
- 控制其它 App（AX）：辅助功能

## 测试点
- 音量 ±6 后读回值正确、边界夹紧
- 内置屏亮度变化、外接屏失败不崩溃
- 媒体键在 Music/Spotify 生效
- 锁屏后能正常唤醒恢复 tap


## 实现（2026-10-28）：亮度
- `Sources/DisplayBrightness.swift`，动作 `brightness` 的 `op`：nil = 光标所在屏，`external` = 所有外接屏，`builtin` = 内建屏。
- 每块屏先试 DisplayServices（`CanChangeBrightness` 为真才用）；不行且是外接屏 → DDC。
- DDC：IORegistry 找 `DCPAVServiceProxy` 且 `Location = External` → `IOAVServiceCreateWithService`；
  读：写 `82 01 10 AC`，等 40ms，读 12 字节解析 max/current（失败重试 3 次，再失败用上次缓存）；
  写：`84 03 10 hi lo chk` 发两次。增量 = delta × max，至少 1 步。全部在后台串行队列执行。
- 限制：IOAVService ↔ 显示器的对应未做，多块外接屏时一起调；Intel Mac 无 DDC。
- 调试：`GestureKit --ddc-probe` 只读列出外接 DDC 服务数量。

## 实现（2026-10-28）：多外接屏映射
- 目的（取代上节「限制」里多屏一起调的说法）：动作 op 为 nil（光标所在屏）时只调光标下那块外接屏；`external` 调全部外接屏。
- IORegistry 结构（Apple Silicon，IOService 平面）：每个显示端口是一对兄弟节点
  `dispextN@…`（下挂帧缓冲 `AppleCLCD2`，旧系统为 `IOMobileFramebufferShim`）与
  `dcpextN@…` → `iop-dcpextN-nub` → `RTBuddy(DCPEXTN)` → … → `dispextN:dcpav-service-epic:M` → `DCPAVServiceProxy`；
  内建端口是 `disp0` / `dcp`（Mac mini 的 HDMI 也可能走这里，但 `Location = External`）。
  接上显示器时帧缓冲上有 `DisplayAttributes.ProductAttributes`（`ManufacturerID` 三字母 PNP、`ProductID`、`SerialNumber`）和 `EDID UUID`。
- 服务 → 显示器身份：沿父链取节点名得到端口键（`portKey`：`dispext0`/`dcpext0`/`dispext0:…` → `ext0`，`disp0`/`dcp` → `0`），
  取同端口帧缓冲的身份（`identity`：优先 ProductAttributes，否则 EDID UUID 前 8 位 = 厂商 + 字节交换的型号）；
  端口找不到时退回「注册表顺序上最近的前一个未被占用的帧缓冲」（`--ddc-probe` 标注推断）。
- 身份 → `CGDirectDisplayID`（纯函数 `DisplayBrightness.matchServices`）：
  单服务单外接屏直接对应 → 厂商+型号+非零序列号精确 → 厂商+型号唯一 → 同型号多块按注册表顺序 / `CGGetActiveDisplayList` 顺序配对（推断）
  → 身份全未知且数量相等时按顺序（推断）。推断配对首次使用时写一次日志。
- 行为（`DDC.plan`）：每个目标屏都映射到了 → 只给对应服务发 DDC；任一目标没映射 → 回退调全部外接 DDC 屏，并按情形只记一次日志。
  参与匹配的是全部外接屏（含 DisplayServices 可调的 Studio Display），避免把它的 AV 服务误认成 DDC 屏。
- 缓存 (current, max) 按显示器身份（`cacheKey`：有序列号用 厂商/型号/序列号，否则再加 displayID）而不是服务下标。
- 枚举与 DDC 都在 `DDC.queue` 串行执行；枚举只读（遍历注册表，不发 I²C）。
- 调试：`GestureKit --ddc-probe` 只读输出外接 CG 显示器身份、帧缓冲端口/身份、DDC 服务及映射结果。
- 自检：`Sources/SelfTest+DDC.swift`（`ddc:` / `ddc map:` / `ddc plan:` / `ddc cache:` / `ddc probe:`）。
- 未实测：开发机未接外接屏；`DisplayAttributes` 键名来自公开的 IORegistry 结构，macOS 27 内建屏帧缓冲上未见该属性，接外接屏后需用 `--ddc-probe` 确认。
