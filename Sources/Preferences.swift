import SwiftUI
import AppKit

// MARK: - Design tokens (from docs/UI_UX_SPEC.md)

enum UI {
    static let windowBG   = Color(red: 0.914, green: 0.914, blue: 0.918)   // #E9E9EA
    static let cardBG     = Color(red: 0.949, green: 0.949, blue: 0.953)   // #F2F2F3
    static let accent     = Color(red: 0.039, green: 0.518, blue: 1.0)     // #0A84FF
    static let secondary  = Color(red: 0.557, green: 0.557, blue: 0.576)   // #8E8E93
    static let danger     = Color(red: 1.0,   green: 0.231, blue: 0.188)   // #FF3B30
    static let ok         = Color(red: 0.204, green: 0.780, blue: 0.349)   // #34C759
    static let sidebarW: CGFloat = 280
    static let cardRadius: CGFloat = 16
}

// MARK: - Sidebar model

enum PrefPage: Int, CaseIterable, Identifiable {
    case normalMouse, hotCorners, history, blacklist, rules, general

    var id: Int { rawValue }

    /// 界面标题（随语言切换）
    var title: String { L(zhTitle) }

    /// 中文原文：L10n 的 key，也供 `--prefs-page 边角触发` 匹配（与界面语言无关）
    var zhTitle: String {
        switch self {
        case .normalMouse: return "普通鼠标"
        case .hotCorners: return "边角触发"
        case .history: return "手势记录"
        case .blacklist: return "黑名单"
        case .rules: return "规则管理"
        case .general: return "通用设置"
        }
    }

    var symbol: String {
        switch self {
        case .normalMouse: return "computermouse"
        case .hotCorners: return "square.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .blacklist: return "hand.raised"
        case .rules: return "list.bullet.rectangle"
        case .general: return "gearshape"
        }
    }

    /// Device pages carry the 按键识别 / 手势设置 sub-tabs.
    var isDevicePage: Bool {
        switch self {
        case .normalMouse: return true
        default: return false
        }
    }
}

// MARK: - Observable state

final class PrefModel: ObservableObject {
    @Published var page: PrefPage = .normalMouse
    @Published var subTab: Int = 1          // 0 按键识别 / 1 手势设置
    @Published var config: Config
    // MARK: 按键识别（P2-12，见 HIDMouse.swift）
    @Published var lastButtonState: String = ""      // 空 = 显示「请按下任意鼠标键」
    /// 已连接的鼠标类设备（只枚举，不打开设备 → 不需要输入监控权限）
    @Published var mice: [HIDMouseInfo] = []
    @Published var selectedMouseID: String?
    /// 当前按住的键（CGEvent 按键号）
    @Published var heldButtons: Set<Int64> = []
    /// 非 nil = 正在手动适配
    @Published var adaptation: ButtonAdaptation?
    /// 上一次手动适配的结果（只展示，不写配置）
    @Published var adaptResult: ButtonAdaptation?
    var selectedMouse: HIDMouseInfo? {
        mice.first { $0.id == selectedMouseID } ?? mice.first
    }
    var device: DeviceInfo.Mouse? { selectedMouse.map(DeviceInfo.mouse(from:)) }
    private var keyIdentifyTokens: [NSObjectProtocol] = []
    private var localButtonMonitor: Any?

    /// 「按键识别」页出现时调用：开始插拔监听 + 接收事件 tap 的按键广播。
    func startKeyIdentify() {
        guard keyIdentifyTokens.isEmpty else { return }
        let nc = NotificationCenter.default
        keyIdentifyTokens.append(nc.addObserver(forName: HIDMouseMonitor.changed, object: nil,
                                                queue: .main) { [weak self] _ in self?.reloadMice() })
        keyIdentifyTokens.append(nc.addObserver(forName: MouseButtonFeed.notification, object: nil,
                                                queue: .main) { [weak self] note in
            guard let b = note.userInfo?["button"] as? Int64,
                  let down = note.userInfo?["down"] as? Bool else { return }
            self?.handleButton(b, down: down)
        })
        HIDMouseMonitor.shared.start()
        reloadMice()
        MouseButtonFeed.isActive = true
        // 没有事件 tap（未授权辅助功能）时，退回到只看本窗口内的点击
        if !MouseButtonFeed.tapRunning {
            localButtonMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                           .otherMouseDown, .otherMouseUp]) { [weak self] e in
                let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type)
                self?.handleButton(Int64(e.buttonNumber), down: down)
                return e
            }
        }
    }

    func stopKeyIdentify() {
        MouseButtonFeed.isActive = false
        keyIdentifyTokens.forEach(NotificationCenter.default.removeObserver)
        keyIdentifyTokens = []
        if let m = localButtonMonitor { NSEvent.removeMonitor(m) }
        localButtonMonitor = nil
        HIDMouseMonitor.shared.stop()
        heldButtons = []
        adaptation = nil
    }

    func reloadMice() {
        let list = HIDMouseMonitor.shared.isRunning ? HIDMouseMonitor.shared.devices
                                                     : HIDMouse.enumerate()
        mice = list
        if selectedMouseID == nil || !list.contains(where: { $0.id == selectedMouseID }) {
            let kind: HIDMouseInfo.Kind? = page == .normalMouse ? .mouse : nil
            selectedMouseID = HIDMouse.preferred(list, kind: kind)?.id
        }
    }

    func handleButton(_ button: Int64, down: Bool) {
        lastButtonState = MouseButtons.stateText(button, down: down)
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        adaptation?.record(button, down: down)
    }

    func beginAdaptation() {
        adaptResult = nil
        adaptation = ButtonAdaptation()
    }

    func finishAdaptation() {
        if let a = adaptation {
            adaptResult = a
            Log.write("button adapt: \(a.recorded.map(String.init).joined(separator: ","))"
                      + " device=\(selectedMouse?.product ?? "?")")
        }
        adaptation = nil
    }
    /// 设备页里选择的应用程序（"default" = 所有应用程序）
    @Published var selectedApp: String = "default"
    /// 手势记录 (selftest gives the model an in-memory one).
    var history: GestureHistory = .shared
    /// 👎 sheet on the 手势记录 page.
    @Published var ratingDraft: RatingDraft?
    /// 手势表格里选中的规则（gesture id），供 − 删除
    @Published var selectedRule: String?
    /// 非 nil 时弹出规则编辑面板
    @Published var editor: RuleEditorState?
    /// 保存后通知引擎（AppDelegate 设置）
    var onSave: ((Config) -> Void)?

    struct Row: Identifiable {
        let id: String          // gesture id (rules.json key)
        let name: String
        let enabled: Bool
        let action: String
        let shortcut: String
        let note: String
    }

    /// 写盘 + 推给引擎。所有设置页的修改都走这里。
    func save(_ c: Config) {
        config = c
        Config.save(c)
        onSave?(c)
    }

    func updateRule(_ id: String, app: String? = nil, _ change: (inout ActionSpec) -> Void) {
        let app = app ?? selectedApp
        var c = config
        guard var spec = c.rulesets[app]?.gestures[id] else { return }
        change(&spec)
        c.rulesets[app]?.gestures[id] = spec
        save(c)
    }

    func deleteRule(_ id: String, app: String? = nil) {
        let app = app ?? selectedApp
        var c = config
        c.rulesets[app]?.gestures[id] = nil
        c.pruneCustomGlyphs()
        if selectedRule == id { selectedRule = nil }
        save(c)
    }

    // MARK: Import / export / reset (规则管理)

    func exportRules() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "GestureKit-rules-\(f.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigIO.export(config, to: url)
            alert(L("已导出"), url.path)
        } catch {
            alert(L("导出失败"), error.localizedDescription)
        }
    }

    func importRules() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json", "BABPreset", "babpreset"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            alert(L("导入失败"), L("无法读取文件。"))
            return
        }
        // 原版 BetterAndBetter 预设（.BABPreset，NSKeyedArchiver 归档）走单独的流程
        if BABImport.looksLikePreset(url: url, data: data) {
            importPreset(data)
            return
        }
        let imported: Config
        do {
            imported = try ConfigIO.decode(data)
        } catch {
            alert(L("导入失败"), error.localizedDescription)
            return
        }
        let count = imported.rulesets.values.reduce(0) { $0 + $1.gestures.count }
        let a = NSAlert()
        a.messageText = L("导入 %d 条规则", count)
        a.informativeText = L("合并：保留现有规则，同一手势以导入文件为准。\n覆盖：用导入文件替换全部设置和规则。\n导入前会自动备份当前 rules.json。")
        a.addButton(withTitle: L("合并"))
        a.addButton(withTitle: L("覆盖"))
        a.addButton(withTitle: L("取消"))
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        ConfigIO.backup()
        save(ConfigIO.combine(current: config, imported: imported,
                              mode: r == .alertFirstButtonReturn ? .merge : .replace))
        selectedApp = "default"
        selectedRule = nil
    }

    /// 导入原版 `.BABPreset`：解析 → 摘要（可导入 / 跳过及原因）→ 合并 / 覆盖 / 取消。
    /// 覆盖只替换规则，GestureKit 自己的设置保持不变（预设里没有这些设置）。
    func importPreset(_ data: Data) {
        let result: BABImport.Result
        do {
            result = try BABImport.parse(data)
        } catch {
            alert(L("导入失败"), error.localizedDescription)
            return
        }
        Log.write("BABPreset parsed: \(result.importedCount) importable, \(result.skipped.count) skipped")
        let a = NSAlert()
        a.informativeText = BABImport.summary(result)
        if !result.skipped.isEmpty { a.accessoryView = Self.skippedListView(BABImport.skippedReport(result)) }
        guard result.importedCount > 0 else {
            a.messageText = L("预设里没有可导入的规则")
            a.addButton(withTitle: L("好"))
            a.runModal()
            return
        }
        a.messageText = L("导入 BetterAndBetter 预设")
        a.informativeText += "\n\n" + L("合并：保留现有规则，同一手势以预设为准。\n覆盖：用预设替换全部规则（设置保持不变）。\n导入前会自动备份当前 rules.json。")
        a.addButton(withTitle: L("合并"))
        a.addButton(withTitle: L("覆盖"))
        a.addButton(withTitle: L("取消"))
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        ConfigIO.backup()
        save(BABImport.apply(result, to: config, mode: r == .alertFirstButtonReturn ? .merge : .replace))
        selectedApp = "default"
        selectedRule = nil
    }

    /// 跳过列表：可滚动、可复制的只读文本框（放进 NSAlert.accessoryView）。
    private static func skippedListView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .systemFont(ofSize: 11)
        tv.string = text
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    func resetAll() {
        let a = NSAlert()
        a.messageText = L("重置全部设置和规则？")
        a.informativeText = L("将恢复出厂规则。当前 rules.json 会先备份到同一目录。")
        a.alertStyle = .warning
        a.addButton(withTitle: L("重置"))
        a.addButton(withTitle: L("取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let kept = ConfigIO.backup()
        save(.defaultConfig)
        selectedApp = "default"
        selectedRule = nil
        alert(L("已重置"), L("备份：%@", kept?.lastPathComponent ?? L("无")))
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// 「通用设置 → 语言」：写配置并立刻切换（设置窗口随 config 发布而重绘，
    /// 菜单栏菜单由 AppDelegate 的 onSave 重建，HUD 每次显示时取当前语言）。
    func setLanguage(_ value: String) {
        var c = config
        c.language = value == "system" ? nil : value
        save(c)                       // onSave → AppDelegate 重建菜单
        L10n.setting = c.language     // 自检里没有 onSave，这里再设一次
    }

    /// Launch-at-login state for the checkbox. Asking SMAppService takes ~40 ms, so it is
    /// read off the main thread when the page appears / after a change, never in `body`.
    @Published var loginItemEnabled = false

    func refreshLoginItem() {
        DispatchQueue.global(qos: .userInitiated).async {
            let on = LoginItem.isEnabled
            DispatchQueue.main.async { self.loginItemEnabled = on }
        }
    }

    func setLoginItem(_ on: Bool) {
        loginItemEnabled = on
        do { try LoginItem.set(on) } catch { alert(L("登录项设置失败：%@", error.localizedDescription), "") }
        refreshLoginItem()
    }

    func setTrail(_ change: (inout TrailConfig) -> Void) {
        var c = config
        var t = c.trail ?? TrailConfig()
        change(&t)
        c.trail = t
        save(c)
    }

    var appKeys: [String] {
        let keys = ["default"] + config.rulesets.keys.filter { $0 != "default" }.sorted()
        return keys
    }

    /// Picker entry that opens the app chooser instead of selecting a group.
    static let addAppTag = "__add_app__"
    /// Picker entry that deletes the selected app's own rule group.
    static let removeAppTag = "__remove_app__"

    /// Opens the app chooser after the picker menu has closed. Selftest replaces it.
    lazy var presentAddApp: () -> Void = { [unowned self] in DispatchQueue.main.async { self.addApp() } }
    /// Asks before deleting an app group (true = delete). Selftest replaces it.
    lazy var confirmRemoveApp: (String) -> Bool = { [unowned self] app in
        let n = self.config.rulesets[app]?.gestures.count ?? 0
        let a = NSAlert()
        a.messageText = L("删除「%@」的专属规则？", self.appTitle(app))
        a.informativeText = L("这个应用的 %d 条专属规则会被删除，之后它沿用「所有应用程序」的规则。删除前会自动备份 rules.json。", n)
        a.addButton(withTitle: L("删除"))
        a.addButton(withTitle: L("取消"))
        return a.runModal() == .alertFirstButtonReturn
    }

    /// App picker binding: picking 「添加应用程序…」 opens the chooser and keeps the current group.
    var appSelection: Binding<String> {
        Binding(get: { self.selectedApp },
                set: { v in
                    if v == PrefModel.addAppTag {
                        self.presentAddApp()
                    } else if v == PrefModel.removeAppTag {
                        let app = self.selectedApp
                        DispatchQueue.main.async { self.removeApp(app) }   // alert after the menu closes
                    } else {
                        self.selectedApp = v
                    }
                })
    }

    /// 「删除专属规则…」: drop the app's own rule group (after a confirmation and a backup).
    func removeApp(_ app: String) {
        guard app != "default", config.rulesets[app] != nil, confirmRemoveApp(app) else { return }
        ConfigIO.backup(tag: "before-remove-app")
        save(PrefModel.removingApp(app, from: config))
        selectedApp = "default"
    }

    /// Pure: `config` without `app`'s rule group (and without drawn shapes only it used).
    static func removingApp(_ app: String, from config: Config) -> Config {
        guard app != "default" else { return config }
        var c = config
        c.rulesets[app] = nil
        c.pruneCustomGlyphs()
        return c
    }

    /// 「添加应用程序…」: pick any .app; it gets its own (empty) rule group — gestures it
    /// doesn't define keep using 所有应用程序 — and becomes the selected group.
    func addApp() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.message = L("选择一个应用程序，为它单独设置手势")
        panel.prompt = L("添加")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bid = Bundle(url: url)?.bundleIdentifier, !bid.isEmpty else {
            alert(L("无法添加"), L("「%@」没有 Bundle ID。", url.lastPathComponent)); return
        }
        appTitles[bid] = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        if config.rulesets[bid] == nil {
            var c = config
            c.rulesets[bid] = Ruleset(gestures: [:])
            save(c)
        }
        selectedApp = bid
    }

    /// bundle id → display name. Views ask for these on every redraw (pickers, sorting),
    /// and the running-apps lookup costs ~0.4 ms each time.
    private var appTitles: [String: String] = [:]

    func appTitle(_ key: String) -> String {
        if key == "default" { return L("所有应用程序") }
        if let cached = appTitles[key] { return cached }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: key).first?.localizedName
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
                .flatMap { FileManager.default.displayName(atPath: $0.path) as String? }
                .map { ($0 as NSString).deletingPathExtension }
        appTitles[key] = name ?? key
        return name ?? key
    }

    init(config: Config) { self.config = config }

    func ruleset(for page: PrefPage) -> Ruleset? {
        config.rulesets["default"]
    }

    /// Human-readable gesture name, matching the original wording.
    static func gestureName(_ id: String) -> String {
        if id.hasPrefix("corner.") {
            let parts = id.split(separator: ".").map(String.init)
            let corner = ["topLeft": L("左上角"), "topRight": L("右上角"),
                          "bottomLeft": L("左下角"), "bottomRight": L("右下角")][parts.count > 1 ? parts[1] : ""] ?? parts[1]
            return parts.count > 2 && parts[2] == "up" ? L("%@滚轮向上", corner) : L("%@滚轮向下", corner)
        }
        if id.hasPrefix(GlyphLibrary.customPrefix) {
            return L("按住右键 + 自定义图形 ") + String(id.dropFirst(GlyphLibrary.customPrefix.count))
        }
        if id.hasPrefix("twoKey.key.") {
            return L("按住右键 + ") + String(id.dropFirst("twoKey.key.".count)).uppercased()
        }
        if id.hasPrefix("twoKey.") {
            let suffix = String(id.dropFirst("twoKey.".count))
            let polyline = ["upThenLeft": "上左", "upThenRight": "上右", "downThenLeft": "下左", "downThenRight": "下右",
                            "upThenDown": "上下"]
            let glyph = GlyphLibrary.directionGlyphs[suffix] ?? ""
            if let name = polyline[suffix] { return L("按住右键 + ") + L(name) + " " + glyph }
            return L("按住右键 + ") + glyph
        }
        return id
    }

    /// Gesture-id prefix of the rules a settings page shows.
    static func rulePrefix(for page: PrefPage) -> String {
        switch page {
        case .hotCorners: return "corner."
        default:          return "twoKey."
        }
    }

    /// 「重置」：this page's rules for `app` go back to the factory rules (other pages untouched).
    static func resetRules(_ config: Config, page: PrefPage, app: String) -> Config {
        let prefix = rulePrefix(for: page)
        var c = config
        var gestures = c.rulesets[app]?.gestures ?? [:]
        gestures = gestures.filter { !$0.key.hasPrefix(prefix) }
        for (id, spec) in Config.defaultConfig.rulesets[app]?.gestures ?? [:] where id.hasPrefix(prefix) {
            gestures[id] = spec
        }
        c.rulesets[app] = Ruleset(gestures: gestures)
        c.pruneCustomGlyphs()
        return c
    }

    func resetPage() {
        let before = rows(for: page).count
        let after = PrefModel.resetRules(config, page: page, app: selectedApp)
            .rulesets[selectedApp]?.gestures.keys.filter { $0.hasPrefix(PrefModel.rulePrefix(for: page)) }.count ?? 0
        let a = NSAlert()
        a.messageText = L("重置「%@」的规则？", page.title)
        a.informativeText = L("当前 %d 条将恢复为出厂的 %d 条（仅限「%@」，其它页面不变）。会先备份当前 rules.json。",
                              before, after, appTitle(selectedApp))
        a.alertStyle = .warning
        a.addButton(withTitle: L("重置"))
        a.addButton(withTitle: L("取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ConfigIO.backup()
        selectedRule = nil
        save(PrefModel.resetRules(config, page: page, app: selectedApp))
    }

    func showVersionInfo() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        alert(L("GestureKit %@", v), L("GestureKit 不联网，不会自动检查更新。新版本请重新编译安装（./build.sh --install）。"))
    }

    func rows(for page: PrefPage) -> [Row] {
        guard let rs = config.rulesets[selectedApp] ?? config.rulesets["default"] else { return [] }
        let prefix = PrefModel.rulePrefix(for: page)
        let filtered = rs.gestures.keys.filter { $0.hasPrefix(prefix) }
        return filtered.sorted().map { key in
            let a = rs.gestures[key]!
            return Row(id: key, name: PrefModel.gestureName(key), enabled: a.enabled != false,
                       action: ActionCatalog.title(for: a),
                       shortcut: a.type == "shortcut" ? (a.label ?? "") : "",
                       note: a.note ?? "")
        }
    }

}

// MARK: - Root view

struct PreferencesView: View {
    @ObservedObject var model: PrefModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.35)
            content
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(UI.windowBG)
        .coordinateSpace(name: ClickTargets.space)
        .sheet(item: $model.editor) { state in
            RuleEditorView(model: model, state: state)
        }
        .onChange(of: model.page) { _ in model.selectedRule = nil }
        .onChange(of: model.selectedApp) { _ in model.selectedRule = nil }
    }

    private func enabledToggle(_ row: PrefModel.Row) -> some View {
        Toggle("", isOn: Binding(
            get: { row.enabled },
            set: { v in model.updateRule(row.id) { $0.enabled = v ? nil : false } }))
            .toggleStyle(.checkbox).labelsHidden()
    }

    private func trailBinding<T>(_ key: WritableKeyPath<TrailConfig, T>) -> Binding<T> {
        Binding(get: { (model.config.trail ?? TrailConfig())[keyPath: key] },
                set: { v in model.setTrail { $0[keyPath: key] = v } })
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                // The app icon itself (Resources/AppIcon.icns, scripts/make-icon.swift)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 76, height: 76)
                Text(L("GestureKit：%@", appVersion))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 18)
            .padding(.bottom, 22)

            ForEach(PrefPage.allCases) { p in
                sidebarItem(p)
            }
            Spacer(minLength: 8)
        }
        .frame(width: UI.sidebarW)
        .padding(.horizontal, 12)
    }

    private func sidebarItem(_ p: PrefPage) -> some View {
        let selected = model.page == p
        return Button {
            model.page = p
        } label: {
            HStack(spacing: 10) {
                Image(systemName: p.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                    .foregroundColor(selected ? .white : UI.secondary)
                Text(p.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(selected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? UI.accent : Color.clear)
            )
            // A plain button only takes clicks on its opaque content (icon + text); the
            // clear background of unselected rows let most clicks fall through.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(p.title))
        .clickTarget(p.title)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if model.page.isDevicePage || model.page == .hotCorners {
            VStack(spacing: 0) {
                if model.page.isDevicePage { segmentedHeader }
                ScrollView {
                    VStack(spacing: 24) {
                        if model.page == .hotCorners {
                            hotCornerCard
                        } else if model.subTab == 1 {
                            gestureCard
                        } else {
                            keyIdentifyCards
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                }
                bottomBar
            }
        } else {
            ScrollView {
                VStack(spacing: 24) {
                    switch model.page {
                    case .general: generalCards
                    case .rules:   rulesCards
                    case .blacklist: blacklistCard
                    case .history:   HistoryPage(model: model, history: model.history)
                    default:       EmptyView()
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 24)
            }
        }
    }

    private var segmentedHeader: some View {
        HStack {
            Spacer()
            // Always laid out (hidden off the 手势设置 tab) so the tabs never shift sideways
            // under the cursor when the selection changes.
            Picker("", selection: model.appSelection) {
                ForEach(model.appKeys, id: \.self) { k in
                    Text(model.appTitle(k)).tag(k)
                }
                Divider()
                Text(L("添加应用程序…")).tag(PrefModel.addAppTag)
                if model.selectedApp != "default" {
                    Text(L("删除「%@」的专属规则…", model.appTitle(model.selectedApp))).tag(PrefModel.removeAppTag)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .padding(.trailing, 12)
            .opacity(model.subTab == 1 ? 1 : 0)
            .disabled(model.subTab != 1)
            .accessibilityHidden(model.subTab != 1)
            HStack(spacing: 0) {
                ForEach(Array([L("按键识别"), L("手势设置")].enumerated()), id: \.offset) { i, t in
                    Button { model.subTab = i } label: {
                        Text(t)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(model.subTab == i ? .white : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(model.subTab == i ? UI.accent : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(t))
                    .clickTarget(t)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.75)))
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    // MARK: Cards

    private func card<C: View>(_ title: String, symbol: String, tint: Color,
                               @ViewBuilder body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint)
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: symbol)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white))
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            body()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous).fill(UI.cardBG))
    }

    private var keyIdentifyCards: some View {
        VStack(spacing: 24) {
            card(L("鼠标硬件信息"), symbol: "computermouse", tint: UI.accent) {
                if model.mice.count > 1 {
                    Picker(L("设备："), selection: Binding(
                        get: { model.selectedMouse?.id ?? "" },
                        set: { model.selectedMouseID = $0 })) {
                        ForEach(model.mice) { d in Text(d.displayName).tag(d.id) }
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: 420)
                } else if model.mice.isEmpty {
                    Text(L("未检测到鼠标类设备")).font(.system(size: 12)).foregroundColor(UI.secondary)
                }
                HStack(spacing: 0) {
                    labelValue(L("产品型号："), model.device?.product ?? "—")
                    labelValue(L("制造商："), model.device?.manufacturer ?? "—")
                }
                HStack(spacing: 0) {
                    labelValue(L("连接方式："), model.device?.transport ?? "—")
                    labelValue(L("产品 ID："), model.device?.productID ?? "—")
                }
                HStack(spacing: 0) {
                    labelValue(L("厂商 ID："), model.device?.vendorID ?? "—")
                    labelValue(L("按键数："), model.device?.buttons ?? "—")
                }
                if let hint = model.selectedMouse?.driverHint {
                    Text(hint).font(.system(size: 11)).foregroundColor(UI.secondary)
                }
            }
            card(L("鼠标按键信息"), symbol: "computermouse.fill", tint: .orange) {
                HStack {
                    Spacer()
                    Text(model.lastButtonState.isEmpty ? L("请按下任意鼠标键") : model.lastButtonState)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(UI.danger)
                    Spacer()
                }
                .padding(.top, 18)
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(0..<8, id: \.self) { i in
                        let held = model.heldButtons.contains(Int64(i))
                        Text(MouseButtons.name(Int64(i)))
                            .font(.system(size: 11, weight: held ? .semibold : .regular))
                            .foregroundColor(held ? .white : .primary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(held ? UI.accent : Color.white.opacity(0.75)))
                    }
                    Spacer()
                }
                .padding(.bottom, 8)
                Text(L("*单击鼠标按键，按键状态将在此处显示。若未正确识别，请点按下方手动适配按钮"))
                    .font(.system(size: 11)).foregroundColor(UI.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                if !MouseButtonFeed.tapRunning {
                    Text(L("未开启「辅助功能」权限：只能识别在本窗口内的点击"))
                        .font(.system(size: 11)).foregroundColor(UI.danger)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            card(L("鼠标按键手动适配"), symbol: "computermouse.badge.plus", tint: .purple) {
                if let a = model.adaptation {
                    Text(L("请依次按下鼠标上除左键以外的每个按键（右键、滚轮键、侧键…），每个键按一次，然后点「完成」。"))
                        .font(.system(size: 12))
                    ForEach(a.lines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
                    if a.recorded.isEmpty {
                        Text(L("等待按键…")).font(.system(size: 12)).foregroundColor(UI.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(L("取消")) { model.adaptation = nil }.buttonStyle(.bordered)
                        Button(L("完成")) { model.finishAdaptation() }.buttonStyle(.borderedProminent)
                        Spacer()
                    }
                } else {
                    if let r = model.adaptResult {
                        ForEach(r.lines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
                        Text(r.summary(expected: model.selectedMouse?.buttonCount ?? 0))
                            .font(.system(size: 12)).foregroundColor(UI.secondary)
                    }
                    HStack {
                        Spacer()
                        Button(model.adaptResult == nil ? L("手动适配") : L("重新适配")) { model.beginAdaptation() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        Spacer()
                    }
                }
                Text(L("*第 6–8 键若无反应，可能被厂商驱动占用，或该键只经 HID 厂商页上报（需「输入监控」权限，当前未启用）"))
                    .font(.system(size: 11)).foregroundColor(UI.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear { model.startKeyIdentify() }
        .onDisappear { model.stopKeyIdentify() }
    }

    private var gestureCard: some View {
        card(L("手势规则"), symbol: "hand.draw", tint: UI.accent) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(L("启用")).lineLimit(1).frame(width: 56)
                    Text(L("手势")).frame(width: 170, alignment: .leading)
                    Text(L("动作")).frame(width: 130, alignment: .leading)
                    Text(L("快捷键")).frame(width: 70, alignment: .leading)
                    Text(L("备注")).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.55))

                if model.selectedApp != "default" {
                    Text(L("「%@」专属规则；这里没有的手势沿用「所有应用程序」的规则", model.appTitle(model.selectedApp)))
                        .font(.system(size: 11)).foregroundColor(UI.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                if model.rows(for: model.page).isEmpty {
                    Text(L("暂无规则，点左下角 + 添加"))
                        .font(.system(size: 12)).foregroundColor(UI.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
                ForEach(model.rows(for: model.page)) { row in
                    HStack(spacing: 12) {
                        enabledToggle(row).frame(width: 56)
                        Text(row.name).frame(width: 170, alignment: .leading).lineLimit(1)
                        Text(row.action).frame(width: 130, alignment: .leading).lineLimit(1)
                        Text(row.shortcut).frame(width: 70, alignment: .leading).lineLimit(1)
                            .foregroundColor(UI.secondary)
                        Text(row.note).frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .frame(height: 34)
                    .modifier(RuleRowStyle(model: model, row: row))
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private var hotCornerCard: some View {
        card(L("边角触发"), symbol: "square.grid.2x2", tint: UI.accent) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(L("启用")).lineLimit(1).frame(width: 56)
                    Text(L("边角触发")).frame(width: 200, alignment: .leading)
                    Text(L("动作")).frame(width: 160, alignment: .leading)
                    Text(L("备注")).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.55))

                ForEach(model.rows(for: .hotCorners)) { row in
                    HStack(spacing: 12) {
                        enabledToggle(row).frame(width: 56)
                        Text(row.name).frame(width: 200, alignment: .leading).lineLimit(1)
                        Text(row.action).frame(width: 160, alignment: .leading).lineLimit(1)
                        Text(row.note).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .frame(height: 34)
                    .modifier(RuleRowStyle(model: model, row: row))
                    Divider().opacity(0.4)
                }
            }
        }
    }

    private var generalCards: some View {
        generalCardsContent.onAppear { model.refreshLoginItem() }
    }

    private var generalCardsContent: some View {
        VStack(spacing: 24) {
            card(L("启动 & 显示"), symbol: "rocket", tint: .red) {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle(L("开机自启动"), isOn: Binding(
                            get: { model.loginItemEnabled },
                            set: { model.setLoginItem($0) })).toggleStyle(.checkbox)
                        Toggle(L("菜单栏显示图标"), isOn: Binding(
                            get: { model.config.showMenuBarIcon ?? true },
                            set: { v in var c = model.config; c.showMenuBarIcon = v; model.save(c) }))
                            .toggleStyle(.checkbox)
                        if model.config.showMenuBarIcon == false {
                            Text(L("*图标已隐藏：在访达或启动台里再次打开 GestureKit 即可回到这里"))
                                .font(.system(size: 10)).foregroundColor(UI.secondary)
                        }
                        HStack {
                            Text(L("语言："))
                            Picker("", selection: Binding(
                                get: { L10n.normalized(model.config.language) },
                                set: { model.setLanguage($0) })) {
                                Text(L("跟随系统")).tag("system")
                                Text("中文").tag("zh")          // 语言名用其本身的文字，不翻译
                                Text("English").tag("en")
                            }.labelsHidden().frame(width: 140)
                        }
                    }
                    Spacer()
                }
            }
            card(L("鼠标手势"), symbol: "computermouse", tint: .blue) {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L("画手势时按住："))
                            Picker("", selection: Binding(
                                get: { model.config.gestureButton ?? "chord" },
                                set: { v in var c = model.config; c.gestureButton = v == "chord" ? nil : v; model.save(c) })) {
                                Text(L("右键")).tag("right")
                                Text(L("左右双键")).tag("chord")
                            }.labelsHidden().frame(width: 140)
                        }
                        Text(L("*按住右键：画完松开执行动作；只单击右键（没画）时右键菜单照常弹出\n*两种方式共用同一套手势规则，按住时按字母键的规则也照样可用"))
                            .font(.system(size: 10)).foregroundColor(UI.secondary)
                    }
                    Spacer()
                }
            }
            card(L("提示信息"), symbol: "cursorarrow", tint: .purple) {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(L("显示轨迹"), isOn: trailBinding(\.enabled)).toggleStyle(.checkbox)
                        HStack {
                            Text(L("轨迹颜色："))
                            ColorPicker("", selection: Binding(
                                get: { Color(GestureTrail.color(hex: (model.config.trail ?? TrailConfig()).color) ?? .systemTeal) },
                                set: { c in model.setTrail { $0.color = GestureTrail.hex(NSColor(c)) } }),
                                supportsOpacity: false)
                                .labelsHidden()
                        }
                        HStack {
                            Text(L("轨迹宽度："))
                            Slider(value: trailBinding(\.width), in: 1...10, step: 1).frame(width: 120)
                            Text("\(Int((model.config.trail ?? TrailConfig()).width))")
                        }
                        Toggle(L("提示备注或动作"), isOn: Binding(
                            get: { model.config.showHUD ?? true },
                            set: { v in var c = model.config; c.showHUD = v; model.save(c) }))
                            .toggleStyle(.checkbox)
                        Text(L("*1,优先提示备注,没有备注时提示执行动作\n2,⚠️如果备注仅仅是空格,将不提示这条规则"))
                            .font(.system(size: 10)).foregroundColor(UI.secondary)
                        Toggle(L("没认出或未执行时提示"), isOn: Binding(
                            get: { model.config.showUnrecognized ?? true },
                            set: { v in var c = model.config; c.showUnrecognized = v ? nil : false; model.save(c) }))
                            .toggleStyle(.checkbox)
                    }
                    Spacer()
                }
            }
        }
    }

    private var rulesCards: some View {
        VStack(spacing: 24) {
            card(L("导入/导出"), symbol: "square.and.arrow.up", tint: .green) {
                HStack(spacing: 80) {
                    Spacer()
                    Button { model.importRules() } label: { bigIconButton(L("导入规则"), "square.and.arrow.down.fill").contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                    Button { model.exportRules() } label: { bigIconButton(L("导出规则"), "square.and.arrow.up.fill").contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 8)
                Text(L("导入支持 GestureKit 规则（.json）和 BetterAndBetter 预设（.BABPreset）。导入前会显示可导入与跳过的规则，并自动备份当前规则；保存设置时每天自动备份一次，保留最近 5 份。"))
                    .font(.system(size: 11)).foregroundColor(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                HStack {
                    Spacer()
                    Button(L("重置全部设置和规则")) { model.resetAll() }.buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }

    private func bigIconButton(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34))
                .foregroundColor(Color(red: 0.35, green: 0.75, blue: 1.0))
            Text(title).font(.system(size: 12))
        }
    }

    private var blacklistCard: some View {
        VStack(spacing: 24) {
            card(L("应用程序黑名单"), symbol: "hand.raised", tint: .purple) {
                Text(L("*当黑名单中的应用程序激活时，手势将暂停；切换到其它 App 自动恢复"))
                    .font(.system(size: 11)).foregroundColor(UI.secondary)
                VStack(spacing: 0) {
                    if (model.config.blacklist ?? []).isEmpty {
                        Text(L("暂无条目")).font(.system(size: 12)).foregroundColor(UI.secondary)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(model.config.blacklist ?? [], id: \.self) { id in
                            HStack(spacing: 12) {
                                Image(systemName: "app.dashed").foregroundColor(UI.secondary)
                                Text(id).font(.system(size: 12))
                                Spacer()
                                Button {
                                    var c = model.config
                                    c.blacklist?.removeAll { $0 == id }
                                    model.save(c)
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundColor(UI.secondary)
                            }
                            .frame(height: 34)
                            Divider().opacity(0.4)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button(L("添加当前前台 App")) {
                        guard let app = NSWorkspace.shared.frontmostApplication,
                              let id = app.bundleIdentifier else { return }
                        var c = model.config
                        if c.blacklist == nil { c.blacklist = [] }
                        if !(c.blacklist!.contains(id)) { c.blacklist!.append(id) }
                        model.save(c)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundColor(.primary)
            Text(value).font(.system(size: 12)).foregroundColor(.primary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if (model.page.isDevicePage && model.subTab == 1) || model.page == .hotCorners {
                Button("+") { model.editor = RuleEditorState(RuleDraft.new(model: model)) }
                    .buttonStyle(.bordered).frame(width: 34)
                    .accessibilityLabel(Text(L("添加规则")))
                    .disabled(RuleDraft.gestureOptions(for: model.page).isEmpty)
                Button("−") {
                    if let id = model.selectedRule { model.deleteRule(id) }
                }
                .buttonStyle(.bordered).frame(width: 34)
                .accessibilityLabel(Text(L("删除所选规则")))
                .disabled(model.selectedRule == nil)
            }
            Spacer()
            if model.page == .general {
                Button(L("版本信息")) { model.showVersionInfo() }.buttonStyle(.bordered)
            } else if model.page.isDevicePage || model.page == .hotCorners {
                Button(L("重置")) { model.resetPage() }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 14)
        .background(UI.windowBG)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

// MARK: - Window controller

final class PreferencesWindowController: NSWindowController {
    private static var shared: PreferencesWindowController?

    static func show(model: PrefModel) {
        if let w = shared {
            w.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "GestureKit"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // Not movable by background: a click that moved a few points became a window drag
        // and never reached the button (the transparent title bar still moves the window).
        win.isMovableByWindowBackground = false
        win.contentView = FirstClickHostingView(rootView: PreferencesView(model: model))
        win.center()
        let wc = PreferencesWindowController(window: win)
        shared = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Takes the first click even while the window is inactive, so a click on the settings
/// window after using another app acts immediately instead of only focusing the window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
