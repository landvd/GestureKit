import SwiftUI
import AppKit

/// What the add/edit rule sheet is working on (「+」 adds: pick the gesture, then the
/// action, in a sheet; double-click a row to edit).
struct RuleDraft: Identifiable {
    static let shortcutChoice = "shortcut"
    static let openAppChoice = "openApp"
    static let openURLChoice = "openURL"
    static let typeTextChoice = "typeText"
    static let runShortcutChoice = "runShortcut"
    /// Action picker entries that carry their own parameters (not in ActionCatalog.choices).
    static let parameterChoices = [shortcutChoice, openAppChoice, openURLChoice,
                                   typeTextChoice, runShortcutChoice]
    /// Gesture picker entry for "draw your own shape".
    static let customChoice = "twoKey.custom.*"

    let id = UUID()
    var page: PrefPage
    var app: String
    var gestureID: String = ""          // picked from the list
    var actionID: String = ""           // ActionCatalog.Choice.id or `shortcutChoice`
    var shortcut: RecordedKey?          // when actionID == shortcutChoice
    var appBundleID = ""                // openAppChoice
    var appPath = ""
    var urlText = ""                    // openURLChoice: URL or local path
    var typedText = ""                  // typeTextChoice
    var shortcutName = ""               // runShortcutChoice
    var note: String = ""
    /// customChoice: the recorded stroke (view coords, y down) and, when editing, its name.
    var customStroke: [CGPoint] = []
    var customName: String?
    /// Set when editing: the rule being replaced.
    var original: (app: String, gesture: String, enabled: Bool?)?

    struct RecordedKey: Equatable {
        var code: Int
        var flags: UInt64
        var label: String { ActionCatalog.keyLabel(code: code, flags: flags) }
    }

    static func new(model: PrefModel) -> RuleDraft {
        var d = RuleDraft(page: model.page, app: model.selectedApp)
        // First gesture this app has no rule for yet (so the sheet doesn't open on an overwrite warning).
        let taken = model.config.rulesets[model.selectedApp]?.gestures ?? [:]
        let options = gestureOptions(for: model.page)
        d.gestureID = (options.first { taken[$0.id] == nil } ?? options.first)?.id ?? ""
        d.actionID = ActionCatalog.choices.first?.id ?? ""
        return d
    }

    static func edit(model: PrefModel, id: String) -> RuleDraft? {
        let app = model.config.rulesets[model.selectedApp] != nil ? model.selectedApp : "default"
        guard let spec = model.config.rulesets[app]?.gestures[id] else { return nil }
        var d = RuleDraft(page: model.page, app: app)
        d.original = (app, id, spec.enabled)
        if id.hasPrefix(GlyphLibrary.customPrefix) {
            let name = String(id.dropFirst(GlyphLibrary.customPrefix.count))
            d.gestureID = customChoice
            d.customName = name
            d.customStroke = model.config.customGlyphs?[name] ?? []
        } else {
            d.gestureID = id
        }
        if spec.type == "shortcut" {
            d.actionID = shortcutChoice
            if let code = spec.keyCode {
                d.shortcut = RecordedKey(code: code, flags: UInt64(spec.modifiers ?? 0))
            }
        } else if spec.type == "openApp" {
            d.actionID = openAppChoice
            d.appBundleID = spec.bundleID ?? ""
            d.appPath = spec.path ?? ""
        } else if spec.type == "openURL" {
            d.actionID = openURLChoice
            d.urlText = spec.url ?? ""
        } else if spec.type == "typeText" {
            d.actionID = typeTextChoice
            d.typedText = spec.text ?? ""
        } else if spec.type == "runShortcut" {
            d.actionID = runShortcutChoice
            d.shortcutName = spec.shortcutName ?? ""
        } else {
            d.actionID = choiceID(for: spec)
        }
        d.note = spec.note ?? ""
        return d
    }

    static func choiceID(for spec: ActionSpec) -> String { ActionCatalog.choiceID(for: spec) }

    /// The rules.json key this draft writes to, or nil while incomplete.
    func resolvedGestureID(in config: Config) -> String? {
        if gestureID == RuleDraft.customChoice {
            guard RuleDraft.isUsableStroke(customStroke) else { return nil }
            return GlyphLibrary.customPrefix + (customName ?? config.nextCustomGlyphName())
        }
        return gestureID.isEmpty ? nil : gestureID
    }

    /// Same 30 pt minimum the matcher applies to drawn strokes.
    static func isUsableStroke(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 2, let f = pts.first else { return false }
        return pts.contains { abs($0.x - f.x) > ShapeMatcher.minSize || abs($0.y - f.y) > ShapeMatcher.minSize }
    }

    var resolvedSpec: ActionSpec? {
        var spec: ActionSpec
        if actionID == RuleDraft.shortcutChoice {
            guard let k = shortcut else { return nil }
            spec = ActionSpec(type: "shortcut", keyCode: k.code, modifiers: UInt32(k.flags),
                              label: k.label, op: nil, delta: nil)
        } else if actionID == RuleDraft.openAppChoice {
            let bid = appBundleID.trimmingCharacters(in: .whitespaces)
            let path = appPath.trimmingCharacters(in: .whitespaces)
            guard !bid.isEmpty || !path.isEmpty else { return nil }
            spec = ActionSpec(type: "openApp", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil)
            spec.bundleID = bid.isEmpty ? nil : bid
            spec.path = path.isEmpty ? nil : path
            spec.label = ActionCatalog.title(for: spec)
        } else if actionID == RuleDraft.openURLChoice {
            let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Actions.resolveURL(raw) != nil else { return nil }
            spec = ActionSpec(type: "openURL", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil)
            spec.url = raw
            spec.label = ActionCatalog.title(for: spec)
        } else if actionID == RuleDraft.typeTextChoice {
            guard !typedText.isEmpty else { return nil }
            spec = ActionSpec(type: "typeText", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil)
            spec.text = typedText
            spec.label = ActionCatalog.title(for: spec)
        } else if actionID == RuleDraft.runShortcutChoice {
            let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            spec = ActionSpec(type: "runShortcut", keyCode: nil, modifiers: nil, label: nil, op: nil, delta: nil)
            spec.shortcutName = name
            spec.label = ActionCatalog.title(for: spec)
        } else {
            guard let choice = ActionCatalog.choices.first(where: { $0.id == actionID }) else { return nil }
            spec = choice.spec
        }
        spec.note = note.isEmpty ? nil : note
        spec.enabled = original?.enabled
        return spec
    }

    /// Write into a config (pure, so --selftest can check it).
    func apply(to config: Config) -> Config? {
        guard let gid = resolvedGestureID(in: config), let spec = resolvedSpec else { return nil }
        var c = config
        if let o = original { c.rulesets[o.app]?.gestures[o.gesture] = nil }
        if c.rulesets[app] == nil { c.rulesets[app] = Ruleset(gestures: [:]) }
        c.rulesets[app]!.gestures[gid] = spec
        if gid.hasPrefix(GlyphLibrary.customPrefix) {
            var glyphs = c.customGlyphs ?? [:]
            glyphs[String(gid.dropFirst(GlyphLibrary.customPrefix.count))] = customStroke
            c.customGlyphs = glyphs
        }
        c.pruneCustomGlyphs()
        return c
    }

    // MARK: - Options

    /// Gestures the sheet offers for a settings page (keyboard uses the recorder).
    static func gestureOptions(for page: PrefPage) -> [(id: String, title: String)] {
        var ids: [String] = []
        switch page {
        case .normalMouse:
            ids = ["left", "right", "up", "down", "upLeft", "upRight", "downLeft", "downRight",
                   "upThenLeft", "upThenRight", "downThenLeft", "downThenRight", "upThenDown"]
                .map { "twoKey.\($0)" }
            ids += "abcdefghijklmnopqrstuvwxyz".map { "twoKey.key.\($0)" } + ["twoKey.key.<"]
            return ids.map { ($0, PrefModel.gestureName($0)) } + [(customChoice, L("自定义绘图…"))]
        case .hotCorners:
            for corner in ["topLeft", "topRight", "bottomLeft", "bottomRight"] {
                ids += ["corner.\(corner).up", "corner.\(corner).down"]
            }
        default:
            break
        }
        return ids.map { ($0, PrefModel.gestureName($0)) }
    }

    /// Click gestures that take over every ordinary click of that kind.
    /// Same-shaped gestures: ↑→ is drawn exactly like the letter F, ↓→ like L.
    /// When a rule set has both, the polyline wins (Recognizer.recognize).
    static func gestureHint(_ id: String) -> String? {
        switch id {
        case "twoKey.upThenRight", "twoKey.key.f":
            return L("提示：「上右 ↑→」与字母 F 画法相同；两条都设置时触发「上右」")
        case "twoKey.downThenRight", "twoKey.key.l":
            return L("提示：「下右 ↓→」与字母 L 画法相同；两条都设置时触发「下右」")
        default:
            return nil
        }
    }

    /// 所有应用程序 + apps that already have rules + running regular apps.
    static func candidateApps(_ model: PrefModel) -> [String] {
        var ids = Set(model.config.rulesets.keys)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { ids.insert(id) }
        }
        ids.remove("default")
        return ["default"] + ids.sorted { model.appTitle($0).localizedCompare(model.appTitle($1)) == .orderedAscending }
    }
}

// MARK: - Row selection

/// Click selects (for −), double-click opens the editor.
struct RuleRowStyle: ViewModifier {
    @ObservedObject var model: PrefModel
    let row: PrefModel.Row

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(model.selectedRule == row.id ? UI.accent.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let d = RuleDraft.edit(model: model, id: row.id) { model.editor = RuleEditorState(d) }
            }
            .onTapGesture { model.selectedRule = row.id }
    }
}

// MARK: - Sheet

/// Editor state lives in an ObservableObject: `@State` is macro-backed in
/// current SDKs and plain `swiftc` has no macro plugin.
final class RuleEditorState: ObservableObject, Identifiable {
    enum Recording { case shortcut }

    @Published var draft: RuleDraft
    @Published private(set) var recording: Recording?
    /// true while the mouse is down on the drawing canvas
    var drawing = false
    private var monitor: Any?

    init(_ draft: RuleDraft) { self.draft = draft }

    // MARK: 打开 App / 运行快捷指令 的候选列表（异步加载，不卡界面）

    struct AppEntry: Hashable { let name: String; let path: String; let bundleID: String? }

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var shortcutNames: [String] = []
    enum ShortcutsStatus { case idle, loading, loaded, failed }
    @Published private(set) var shortcutsStatus: ShortcutsStatus = .idle
    private var appsLoaded = false

    static let appDirectories = ["/Applications", "/Applications/Utilities",
                                 "/System/Applications", "/System/Applications/Utilities"]

    /// .app bundles directly under `dirs` plus running regular apps, de-duplicated by path, sorted by name.
    static func scanApps(dirs: [String], running: [NSRunningApplication]) -> [AppEntry] {
        var byPath: [String: AppEntry] = [:]
        let fm = FileManager.default
        for dir in dirs {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where item.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(item)
                byPath[path] = AppEntry(name: (item as NSString).deletingPathExtension, path: path,
                                        bundleID: Bundle(path: path)?.bundleIdentifier)
            }
        }
        for app in running where app.activationPolicy == .regular && app != NSRunningApplication.current {
            guard let url = app.bundleURL, byPath[url.path] == nil else { continue }
            byPath[url.path] = AppEntry(name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                        path: url.path, bundleID: app.bundleIdentifier)
        }
        return byPath.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `shortcuts list` prints one name per line.
    static func parseShortcutsList(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func loadAppsIfNeeded() {
        guard !appsLoaded else { return }
        appsLoaded = true
        let running = NSWorkspace.shared.runningApplications
        DispatchQueue.global(qos: .userInitiated).async {
            let list = RuleEditorState.scanApps(dirs: RuleEditorState.appDirectories, running: running)
            DispatchQueue.main.async { self.apps = list }
        }
    }

    /// Reads the Shortcuts library in the background (`shortcuts list`, 10 s timeout).
    /// On failure the editor still accepts a typed name.
    func loadShortcutsIfNeeded() {
        guard shortcutsStatus == .idle else { return }
        shortcutsStatus = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var names: [String]?
            do {
                try p.run()
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                if p.terminationStatus == 0 {
                    names = RuleEditorState.parseShortcutsList(String(data: data, encoding: .utf8) ?? "")
                }
            } catch {
                Log.write("shortcuts list failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                self.shortcutNames = names ?? []
                self.shortcutsStatus = names == nil ? .failed : .loaded
            }
        }
    }

    /// NSOpenPanel for an .app; fills bundle id + path.
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.appPath = url.path
        draft.appBundleID = Bundle(url: url)?.bundleIdentifier ?? ""
    }

    /// NSOpenPanel for any file or folder; fills the URL field with its path.
    func chooseFileForURL() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.urlText = url.path
    }

    /// Click, then press a key combination; Esc alone cancels.
    func record(_ which: Recording) {
        stopRecording()
        recording = which
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if !(e.keyCode == 53 && mods.isEmpty) {
                let k = RuleDraft.RecordedKey(code: Int(e.keyCode), flags: UInt64(mods.rawValue))
                self.draft.shortcut = k
            }
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}

struct RuleEditorView: View {
    @ObservedObject var model: PrefModel
    @ObservedObject var state: RuleEditorState

    private var draft: RuleDraft { state.draft }
    private var binding: Binding<RuleDraft> { $state.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.original == nil ? L("添加规则") : L("编辑规则"))
                .font(.system(size: 15, weight: .semibold))

            row(L("应用程序：")) {
                Picker("", selection: binding.app) {
                    ForEach(RuleDraft.candidateApps(model), id: \.self) { Text(model.appTitle($0)).tag($0) }
                }.labelsHidden()
            }

            row(L("手势：")) {
                Picker("", selection: binding.gestureID) {
                    ForEach(RuleDraft.gestureOptions(for: draft.page), id: \.id) { Text($0.title).tag($0.id) }
                }.labelsHidden()
            }

            if draft.gestureID == RuleDraft.customChoice {
                row(L("图形：")) { canvas }
            }

            if let hint = RuleDraft.gestureHint(draft.gestureID) {
                Text(hint).font(.system(size: 10)).foregroundColor(UI.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            row(L("动作：")) {
                Picker("", selection: binding.actionID) {
                    Text(L("快捷键…")).tag(RuleDraft.shortcutChoice)
                    Text(L("打开 App…")).tag(RuleDraft.openAppChoice)
                    Text(L("打开网址或文件…")).tag(RuleDraft.openURLChoice)
                    Text(L("输入文字…")).tag(RuleDraft.typeTextChoice)
                    Text(L("运行快捷指令…")).tag(RuleDraft.runShortcutChoice)
                    ForEach(categories, id: \.self) { cat in
                        Section(header: Text(cat)) {
                            ForEach(ActionCatalog.choices.filter { $0.category == cat }) { c in
                                Text(c.title).tag(c.id)
                            }
                        }
                    }
                }.labelsHidden()
            }

            if draft.actionID == RuleDraft.shortcutChoice {
                row(L("快捷键：")) { recorder(.shortcut, draft.shortcut) }
            }

            if draft.actionID == RuleDraft.openAppChoice { openAppRows }
            if draft.actionID == RuleDraft.openURLChoice { openURLRows }
            if draft.actionID == RuleDraft.typeTextChoice { typeTextRows }
            if draft.actionID == RuleDraft.runShortcutChoice { runShortcutRows }

            row(L("备注：")) {
                TextField(L("可选，HUD 优先显示备注"), text: binding.note)
                    .textFieldStyle(.roundedBorder)
            }

            if let warning { Text(warning).font(.system(size: 11)).foregroundColor(UI.danger) }

            HStack {
                Spacer()
                Button(L("取消")) { close() }.keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.apply(to: model.config) == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onDisappear { state.stopRecording() }
    }

    /// Draw the shape with the mouse; a new drag replaces the previous stroke.
    private var canvas: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white)
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.black.opacity(0.15))
                Path { p in
                    guard let first = draft.customStroke.first else { return }
                    p.move(to: first)
                    for pt in draft.customStroke.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(UI.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if draft.customStroke.isEmpty {
                    Text(L("在此按住鼠标画出图形")).font(.system(size: 11)).foregroundColor(UI.secondary)
                }
            }
            .frame(width: 300, height: 170)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !state.drawing { state.drawing = true; state.draft.customStroke = [] }
                    if let last = state.draft.customStroke.last,
                       hypot(v.location.x - last.x, v.location.y - last.y) < 2 { return }
                    state.draft.customStroke.append(v.location)
                }
                .onEnded { _ in state.drawing = false })
            Text(RuleDraft.isUsableStroke(draft.customStroke) || draft.customStroke.isEmpty
                 ? L("*按住左右键画出同样的形状即可触发（一笔画，起笔方向要一致）")
                 : L("图形太小，请画大一些（至少 30pt）"))
                .font(.system(size: 10)).foregroundColor(UI.secondary)
        }
    }

    // MARK: 新动作的参数区

    /// Picker over installed + running apps; a chosen-by-panel app outside the list is shown too.
    private var openAppRows: some View {
        var entries = state.apps
        if !draft.appPath.isEmpty, !entries.contains(where: { $0.path == draft.appPath }) {
            entries.insert(.init(name: ActionCatalog.appName(bundleID: nil, path: draft.appPath) ?? draft.appPath,
                                 path: draft.appPath, bundleID: draft.appBundleID.isEmpty ? nil : draft.appBundleID),
                           at: 0)
        }
        let selection = Binding<String>(
            get: { state.draft.appPath },
            set: { path in
                state.draft.appPath = path
                state.draft.appBundleID = entries.first { $0.path == path }?.bundleID ?? ""
            })
        return VStack(alignment: .leading, spacing: 6) {
            row(L("App：")) {
                Picker("", selection: selection) {
                    Text(L("请选择")).tag("")
                    ForEach(entries, id: \.path) { Text($0.name).tag($0.path) }
                }.labelsHidden()
                Button(L("选择…")) { state.chooseApp() }
            }
            if !draft.appBundleID.isEmpty {
                hint(L("已在运行时切换到它，否则打开（%@）", draft.appBundleID))
            }
        }
        .onAppear { state.loadAppsIfNeeded() }
    }

    private var openURLRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L("地址：")) {
                TextField(L("https://…、mailto:…，或文件/文件夹路径"), text: binding.urlText)
                    .textFieldStyle(.roundedBorder)
                Button(L("选择文件…")) { state.chooseFileForURL() }
            }
            if !draft.urlText.trimmingCharacters(in: .whitespaces).isEmpty, Actions.resolveURL(draft.urlText) == nil {
                hint(L("无法识别的地址"), danger: true)
            }
        }
    }

    private var typeTextRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L("文字：")) {
                TextEditor(text: binding.typedText)
                    .font(.system(size: 12))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.15)))
            }
            hint(L("触发时在当前光标处输入这段文字；换行会按回车键发送"))
        }
    }

    private var runShortcutRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L("快捷指令：")) {
                TextField(L("快捷指令名称"), text: binding.shortcutName)
                    .textFieldStyle(.roundedBorder)
                if !state.shortcutNames.isEmpty {
                    Menu(L("从列表选择")) {
                        ForEach(state.shortcutNames, id: \.self) { n in
                            Button(n) { state.draft.shortcutName = n }
                        }
                    }.frame(width: 110)
                }
            }
            switch state.shortcutsStatus {
            case .loading: hint(L("正在读取快捷指令列表…"))
            case .failed:  hint(L("读取快捷指令列表失败，可直接输入名称"))
            case .loaded where state.shortcutNames.isEmpty: hint(L("快捷指令 App 里还没有快捷指令，可直接输入名称"))
            default: EmptyView()
            }
            hint(L("想用手势开关勿扰：在快捷指令里建一个「设定专注模式」的快捷指令，再用这个动作运行它"))
        }
        .onAppear { state.loadShortcutsIfNeeded() }
    }

    private func hint(_ text: String, danger: Bool = false) -> some View {
        Text(text).font(.system(size: 10)).foregroundColor(danger ? UI.danger : UI.secondary)
            .padding(.leading, 82).fixedSize(horizontal: false, vertical: true)
    }

    private func recorder(_ which: RuleEditorState.Recording, _ key: RuleDraft.RecordedKey?) -> some View {
        Button(state.recording == which ? L("请按下按键…") : (key?.label ?? L("点击录制"))) {
            state.recording == which ? state.stopRecording() : state.record(which)
        }
        .frame(minWidth: 120)
    }

    private var categories: [String] {
        var seen: [String] = []
        for c in ActionCatalog.choices where !seen.contains(c.category) { seen.append(c.category) }
        return seen
    }

    private var warning: String? {
        guard let gid = draft.resolvedGestureID(in: model.config),
              model.config.rulesets[draft.app]?.gestures[gid] != nil,
              !(draft.original?.app == draft.app && draft.original?.gesture == gid) else { return nil }
        return L("该 App 已有这个手势的规则，保存将覆盖它。")
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 72, alignment: .trailing)
            content()
        }
        .font(.system(size: 12))
    }

    private func save() {
        guard let gid = draft.resolvedGestureID(in: model.config),
              let c = draft.apply(to: model.config) else { return }
        model.save(c)
        model.selectedApp = draft.app
        model.selectedRule = gid
        close()
    }

    private func close() {
        state.stopRecording()
        model.editor = nil
    }
}
