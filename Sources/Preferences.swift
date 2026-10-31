import SwiftUI
import AppKit

// MARK: - Design tokens

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

    /// Device pages: rule list with the per-app picker.
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
    @Published var config: Config
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
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            alert(L("导入失败"), L("无法读取文件。"))
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
                if model.page.isDevicePage { appPickerHeader }
                ScrollView {
                    VStack(spacing: 24) {
                        if model.page == .hotCorners {
                            hotCornerCard
                        } else {
                            gestureCard
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

    private var appPickerHeader: some View {
        HStack {
            Spacer()
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
                if let step = model.config.volumeStep {
                    HStack(spacing: 8) {
                        Text(L("音量每次调节"))
                        Picker("", selection: Binding(
                            get: { step },
                            set: { model.save(model.config.settingVolumeStep($0)) })) {
                            ForEach(Config.volumeSteps, id: \.self) { v in Text("\(Int(v))%").tag(v) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        Text(L("*数值越大调得越快，所有音量规则一起生效"))
                            .font(.system(size: 11)).foregroundColor(UI.secondary)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.top, 14)
                }
            }
        }
    }

    private func scrollSlider(_ title: String, _ hint: String, _ key: WritableKeyPath<Config, Double?>,
                              _ fallback: Double, _ range: ClosedRange<Double>, step: Double,
                              format: String) -> some View {
        let value = model.config[keyPath: key] ?? fallback
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).frame(width: 64, alignment: .leading)
                Slider(value: Binding(get: { value },
                                      set: { v in var c = model.config; c[keyPath: key] = v == fallback ? nil : v; model.save(c) }),
                       in: range, step: step)
                    .frame(width: 180)
                    .accessibilityLabel(Text(title))
                Text(String(format: format, value)).frame(width: 40, alignment: .trailing)
            }
            Text(hint).font(.system(size: 10)).foregroundColor(UI.secondary)
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
                        Toggle(L("Safari：把链接拖到页面内松开，在后台新标签打开"), isOn: Binding(
                            get: { model.config.dragLinkToNewTab ?? true },
                            set: { v in var c = model.config; c.dragLinkToNewTab = v ? nil : false; model.save(c) }))
                            .toggleStyle(.checkbox)
                    }
                    Spacer()
                }
            }
            card(L("滚动"), symbol: "scroll", tint: .teal) {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("平滑滚动"), isOn: Binding(
                            get: { model.config.smoothScrollEnabled ?? true },
                            set: { v in var c = model.config; c.smoothScrollEnabled = v ? nil : false; model.save(c) }))
                            .toggleStyle(.checkbox)
                        Group {
                            scrollSlider(L("最短步长"), L("控制单次滚动的最短距离"),
                                         \.smoothScrollStep, SmoothScroller.Settings.defaultStep,
                                         SmoothScroller.Settings.stepRange, step: 1, format: "%.0f")
                            scrollSlider(L("速度增益"), L("控制滚动距离的放大倍数"),
                                         \.smoothScrollGain, SmoothScroller.Settings.defaultGain,
                                         SmoothScroller.Settings.gainRange, step: 0.125, format: "%.3g")
                            scrollSlider(L("持续时间"), L("控制滚动的缓动持续时间（秒）"),
                                         \.smoothScrollDuration, SmoothScroller.Settings.defaultDuration,
                                         SmoothScroller.Settings.durationRange, step: 0.05, format: "%.2f")
                        }
                        .disabled(model.config.smoothScrollEnabled == false)
                        Text(L("*只作用于普通鼠标滚轮；按住 ⌃⌥⌘⇧ 时、黑名单 App 和屏幕边角不生效"))
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
                Text(L("导入前会自动备份当前规则；保存设置时每天自动备份一次，保留最近 5 份。"))
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
            if model.page.isDevicePage || model.page == .hotCorners {
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
