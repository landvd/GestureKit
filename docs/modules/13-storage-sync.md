# 模块 13 · 配置存储 / 导入导出 / iCloud

## 存储
```
~/Library/Application Support/<App>/
├── config.json          主配置（规则、黑名单、全局开关）
├── presets/             内置预设
├── scripts/             AppleScript 库
└── logs/                日志（环形）
```

## Schema 与版本
```jsonc
{
  "version": 3,
  "global": { "enabled": true, "language": "system", "startAtLogin": true },
  "devices": { "normalMouse": {...}, "magicMouse": {...}, "trackpad": {...}, "keyboard": {...} },
  "rulesets": { "default": [...], "com.apple.Safari": [...] },
  "blacklist": ["com.apple.Terminal"],
  "buttonBlacklist": { "com.apple.Safari": [1, 2] },
  "smoothScroll": { "enabled": true, "speed": 1.0, "perApp": {...} },
  "hud": { "enabled": true, "retention": 1.2 }
}
```
- 读取：`decode` 失败 → 备份坏文件 → 用默认值（不要清空用户数据）。
- 迁移：`migrate(from:to:)` 链式处理，每步可单测。

## 写入策略
- 内存态为唯一真相，变更后 debounce 500ms 落盘（原子写：临时文件 + rename）。
- 退出前强制 flush。
- 写失败重试 3 次，仍失败则提示"配置未保存"。

## 导入/导出
- 导出：整个 config.json + 版本号 + 导出时间。
- 导入：校验 schema → 迁移 → 合并策略（覆盖/合并）由用户选择。
- 按模块导入预设（普通鼠标/妙控鼠标/触控板/键盘/边角/脚本）：
  只替换对应 `devices.<x>` 段。
- 冲突提示：列出将被覆盖的规则条数。

## iCloud
| 方案 | 适用 | 实现 |
|---|---|---|
| `NSUbiquitousKeyValueStore` | 轻量（<1MB） | 存 JSON 字符串，监听 `didChangeExternallyNotification` |
| CloudKit private DB | 大数据/多设备 | `CKRecord` 存文件，`CKModifyRecordsOperation` |

冲突解决：
- 每条规则带 `updatedAt`；合并时新者胜。
- 删除用 tombstone（`deletedAt`），避免"删了又被同步回来"。

## 备份
- 手动"上传到 iCloud"/"从 iCloud 同步"按钮 + 上次时间显示。
- 本地保留最近 5 份自动备份（按天）。

## 测试点
- 损坏 JSON 不丢配置（回退默认 + 备份）
- 版本迁移正确
- 导入只影响选中模块
- iCloud 双向同步不产生重复规则


## 实现（2026-10-28）
- `Sources/ConfigIO.swift`：`export` / `decode` / `combine(current:imported:mode:)` / `backup`。
- 导入：选文件 → 显示条数 → 合并（同一手势以文件为准，黑名单并集，自定义笔画合并）或覆盖。
  合并时全局开关（启用、阈值、HUD、平滑滚轮）保持本机设置。
- 导入、重置前自动备份 `rules.backup-yyyyMMdd-HHmmss.json`（同目录）。
- `Config.loadOrCreate`：文件存在但解析失败时先保存为 `rules.broken-*.json` 再写默认值。
- 写盘改为原子写（`.atomic`）。
- 未做：按模块导入、debounce 落盘、自动备份轮换（保留 5 份）、版本迁移链。

## 实现（2026-10-28）：iCloud 云盘同步
CloudKit / `NSUbiquitousKeyValueStore` 需要付费开发者账号的 iCloud entitlement，自签名用不了，
改为 **iCloud 云盘文件夹同步**；上传下载由系统完成，App 不联网。代码：`Sources/CloudSync.swift`。

- 路径：`~/Library/Mobile Documents/com~apple~CloudDocs/GestureKit/`
  - `rules.json`：Config JSON（去掉本机字段 `cloudSync`，`sortedKeys`）
  - `sync-meta.json`：`version`（元数据格式）、`uploadedAt`（ISO8601）、`device`（`Host.current().localizedName`）、`hash`（SHA256）、`ruleCount`
  - 本机进度：`Application Support/GestureKit/cloudsync-state.json`（`lastSyncedHash`、`ignoredCloudHash`），不进 rules.json
- 可用性：CloudDocs 目录存在即可用；不存在时 UI 提示「请在系统设置里登录 iCloud 并打开 iCloud 云盘」，所有操作抛错/什么都不做。
  云端只有 `.rules.json.icloud` 占位 → 「尚未下载」，调用 `startDownloadingUbiquitousItem` 交给系统，不当成空、不提示。
- 状态判定（纯函数 `CloudSync.classify(local:cloud:lastSynced:)`）：哈希相同 → 一致；只有本地变 → 本地较新；
  只有云端变 → 云端较新；都变（或本机从未同步且不同）→ 冲突；云端无文件 → 云端为空。哈希不含 `cloudSync`。
- 上传：原子写 rules.json → meta，记 `lastSyncedHash`。云端较新/冲突时手动上传先二次确认。
- 恢复：先 `ConfigIO.backup(rules.json, tag: "before-icloud")`，再 `ConfigIO.combine` 合并/覆盖，保留本机 `cloudSync`；
  `lastSyncedHash` = 云端哈希（合并后 → 本地较新，下次自动上传）。
- 自动同步（`Config.cloudSync`，默认关）：`PrefModel.save` → `localDidSave` 去抖 2s；只在「本地较新 / 云端为空」时上传，
  云端有别处改动时不覆盖。启动 2s 后检查一次，之后每 30s 轮询。
- 提示：云端较新/冲突 → 菜单栏 tooltip + 菜单项「iCloud 有新规则…」（点开选 合并/覆盖/忽略），不弹不请自来的模态框。
- 回环防护（`shouldPrompt`）：云端哈希 == 上次同步（自己刚传）、== 已忽略、或 meta 为本机且哈希 == 上次同步 → 不提示；
  同一份云端内容每次运行只回调一次。
- 自检：`SelfTest+Cloud.swift` 31 条，全部在临时目录（假 CloudDocs + 假本地目录）。
- 未做：按规则粒度的 `updatedAt` / tombstone 合并（仍是整包 + 同 id 云端优先）；文件系统事件监听（用轮询代替）。

## 实现（2026-10-28）：原版预设导入与自动备份
代码：`Sources/BABImport.swift`（解析 + 映射）、`Sources/ConfigIO.swift`（自动备份轮换）、
`PrefModel.importRules / importPreset`；自检 `SelfTest+Import.swift`（`bab:*` 24 条、`autobackup:*` 5 条）。

### `.BABPreset` 导入
- 文件是 NSKeyedArchiver 归档的整份偏好字典。**不用 NSKeyedUnarchiver**：`PropertyListSerialization`
  读出 `$objects` / `$top.root`，自己按 `CF$UID` 解引用（二进制里的 UID 对象与 XML 的 `{"CF$UID": n}` 都认），
  还原 `NS.keys/NS.objects`（字典）、`NS.objects`（数组）、`NS.string`、`NS.data`、`NS.pointval`（NSValue 点）、`NS.time`；
  解引用深度上限 64，防循环引用。根不是字典 / 不是归档 / 没有 `ruleOf*` 分组 → 抛错（中文提示），不崩溃。
- 读取分组：`ruleOfNormalMouse`、`ruleOfTrackPad`、`ruleOfMagicMouse`、`ruleOfHotCorners`、`ruleOfKeyboard`；
  每组 `{AppName, "All Rules"}`，`All Applications` → `default`，其余按 bundle id 原样（优先 `BundleID` 类键）。
  `ruleOfAppleScript`（脚本库）不是规则，只在摘要里提示数量。
- 规则：`Enable`（数字或字符串）为 0 → `enabled: false`；`Note` 非空 → `note`；`EnableUnderCursor`/`Optimized` 忽略。
- 手势：` <g>Of2Key` / `!<g>Of2Key` → `twoKey.<方向>` / `twoKey.key.<字母>`（`!` + 方向 = 反向 = 相反方向；
  `!` + 字母按同一字母）；`GlyphLibrary` 没有的字形、`Of3Key` 及以上 → 跳过。
  `CustomizeOf2Key` 的 `Data`（内层归档的 NSValue 点数组，y 向上）→ y 翻转后存进 `customGlyphs`，规则 `twoKey.custom.<n>`。
  `Scroll Up/Down at <Corner> Corner` → `corner.<corner>.up/down`；键盘 `{keyCode, modifierFlags}` → `keyboard.<code>.<flags>`；
  触控板 `2Finger_Swipe_Left/Right` → `trackpad.swipeLeft/Right`（系统翻页），`NFinger_Tap/Swipe_<Dir>[_From <Edge>]/Pinch_In/Out`、
  `1Finger_Tap_<区域>` → `trackpad.*`；妙控鼠标 `1Finger_Tap/Click_<区域>`、`2/3Finger_Tap/Click`、`2Finger_Swipe_<Dir>` → `magicMouse.*`。
  其余（ForceClick、TipTap、LeftFinger…）→ 跳过。
- 修饰键：NSEvent.ModifierFlags 的 ⇧⌃⌥⌘ 位与 CGEventFlags 相同（0x20000/0x40000/0x80000/0x100000），
  只保留这四位（原文件里常带设备相关低位，如 0x100108）。快捷键 label 用 `ActionCatalog.keyLabel` 重新生成。
- 动作：`Shortcut Keys` → `shortcut`；`Preset` 名称先归一化（小写、只留字母数字，兼容 `Open a New Tab`/`OpenaNewTab`/`half_of_Left`），
  查 `BABImport.presetTable`（约 110 个名字 → window / snap / system / volume ±6 / brightness ±0.0625（`External Screen*` → `op: external`）/ quitApp）。
  查不到（如 `Open...`、`A`、勿扰、合盖睡眠、移到下一个空间、滚动截图）或其它动作类型 → 跳过。
- 跳过列表：每条记录 设备 / App / 原手势 / 原动作 / 原因；导入前的确认框显示数量和前 6 条，附带可滚动的完整列表。
- 合并 / 覆盖（`BABImport.apply`）：合并 = 在现有规则上叠加（同手势以预设为准）；覆盖 = 替换全部规则；
  两种方式都**保留 GestureKit 的全局设置**（预设里没有这些设置）。导入的自定义笔画重新编号，避免覆盖已有 `customGlyphs`。
  导入前 `ConfigIO.backup()`。日志只写数量。

### 自动备份轮换
- `Config.save` 写盘前调用 `ConfigIO.autoBackup(configURL)`：当天还没有 `rules.auto-yyyyMMdd.json` 时把**保存前**的
  rules.json 复制过去，然后 `pruneAutoBackups` 只保留最近 5 份（按文件名日期排序）。
- 只删除严格匹配 `rules.auto-<8 位数字>.json` 的文件；`rules.backup-*`、`rules.broken-*` 等一概不动。
- 目录与日期可注入（`autoBackup(file, now:, keep:)`），自检全部在临时目录；自检不调用 `Config.save`。

## 实现（2026-10-28）：按规则合并与删除标记
解决「A 机删掉的规则被 B 机云端版本带回来」「两边都改的同一条规则不知道谁新」。
代码：`Rules.swift`（Config 字段）、`ConfigIO.swift`（`stamp` / `mergeByRule` / `pruneTombstones`）、
`CloudSync.swift`（哈希、恢复、自动合并）、`PrefModel.save`。

- 数据（Config 可选字段，老配置照常解码；没有改过规则时不写）：
  - `ruleMeta: [String: Double]?`：键 `Config.ruleKey(app, gestureId)` = `"<app>\u{1F}<gestureId>"`，值 = 最后修改时间（Unix 秒）。缺键 = 时间未知，按 0。
  - `tombstones: [String: Double]?`：同键 → 删除时间；超过 90 天（`ConfigIO.tombstoneTTL`）清理。
- 打点（`ConfigIO.stamp(old:new:now:)`，在 `PrefModel.save` 里对比保存前后）：内容变了或新增 → `ruleMeta = now`；
  消失 → 墓碑 = now；规则又出现 → 墓碑作废。新配置缺的元数据从旧配置继承（重置/导入构造的 Config 不带元数据）；
  调用方已写了与旧值不同的时间（合并结果带着对方时间）→ 保留调用方的。所有写盘都走 `PrefModel.save`
  （设置页、编辑器、导入、重置、iCloud 恢复、自动合并），`Config.loadOrCreate` 只在无文件/坏文件时写默认配置，无需打点。
- 合并（`ConfigIO.mergeByRule(local:remote:now:)`）：两边都有 → 时间新者胜，相等（含两边都没时间）→ 云端胜；
  只有一边有 → 另一边墓碑比它新则删除，否则保留；结果里与现存规则冲突的墓碑丢弃，墓碑取两边最大值并做 90 天清理。
  全局设置/本机字段以本机为准，黑名单并集；`customGlyphs` 跟随胜出规则（被删规则的笔画随 `pruneCustomGlyphs` 清掉）。
  两边都无元数据时结果与原 `combine(.merge)` 相同。文件导入（.json）仍用 `combine`。
- 使用处：「从 iCloud 恢复 → 合并」；自动同步在去抖到期遇到「云端较新 / 冲突」时，若设置了 `onAutoMerge`
  （`PrefModel.cloud` 的 didSet 设置，回调里 `save(merged)`）→ 合并、上传合并结果、本地落盘，不再提示；
  未设置（自检里的旧用例）→ 保持原行为（不上传、改为提示）。30s 轮询发现云端变化仍只提示，不自动改本地。「覆盖」语义不变。
- 哈希：`ruleMeta` / `tombstones` 上云（`canonicalData` 保留），但内容哈希（`contentData`）去掉它们 ——
  单纯打点/墓碑过期不会让状态在「一致 / 本地较新」间抖动；回环防护（自己上传不提示、同内容不重复提示）仍只看内容。
  代价：两边内容相同、只有元数据不同时视为「已同步」，元数据不会单独上传（不影响结果：内容一致时元数据只影响将来与第三台设备的合并，下次有内容变化时会随之上传）。
- 自检：`SelfTest+Cloud.swift` 新增 15 条（共 46 条 `cloud:`），全部在临时目录。
- 风险/未做：时间来自各机系统时钟，时钟偏差大时「新者胜」可能误判；超过 90 天未同步的设备可能把已删规则带回来；
  自动合并依赖每天一次的 `rules.auto-*` 备份，不额外生成 `before-icloud` 备份。
