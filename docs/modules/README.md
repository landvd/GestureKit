# 模块实现规格（索引）

按模块拆分，每个文件包含：职责、依赖、数据结构、算法、API、边界、错误处理、测试点、代码骨架。

| # | 模块 | 文件 |
|---|---|---|
| 01 | 全局事件采集（CGEventTap） | `01-input-eventtap.md` |
| 02 | HID 设备与鼠标按键 | `02-input-hid-mouse.md` |
| 03 | 触控板/妙控鼠标多指 | `03-input-multitouch.md` |
| 04 | 鼠标手势识别 | `04-recognizer-mouse.md` |
| 05 | 触控板手势识别 | `05-recognizer-touch.md` |
| 06 | 屏幕边角 + 绘图 | `06-hotcorner-drawing.md` |
| 07 | 规则引擎 | `07-rules-engine.md` |
| 08 | 窗口动作（AX） | `08-actions-window.md` |
| 09 | 系统动作（音量/亮度/媒体/锁屏） | `09-actions-system.md` |
| 10 | 输入类动作（快捷键/文本/脚本/打开/菜单） | `10-actions-input-script.md` |
| 11 | 平滑滚轮 | `11-smooth-scroll.md` |
| 12 | HUD | `12-hud.md` |
| 13 | 配置存储/导入导出/iCloud | `13-storage-sync.md` |
| 14 | 权限与生命周期 | `14-permissions-lifecycle.md` |
| 15 | 测试与性能 | `15-testing-performance.md` |

上层文档：
- `../ORIGINAL_FEATURES.md` — 做什么（功能全集）
- `../IMPLEMENTATION.md` — 总体架构与快速对照
