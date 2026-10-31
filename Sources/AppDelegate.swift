import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let tap = EventTap()
    /// Lives on `TapThread`: touch it only through `onEngine`.
    private var engine: GestureEngine!
    /// Main-thread copy of what the engine runs with (menus, HUD, trail, settings read this).
    private var config: Config = .defaultConfig
    private var paused = false
    private var configWatch: DispatchSourceFileSystemObject?
    private var retryTimer: Timer?
    private lazy var prefModel: PrefModel = {
        let m = PrefModel(config: config)
        // 设置窗口里的改动立即生效（无需「重新加载配置」）
        m.onSave = { [weak self] cfg in
            self?.setEngineConfig(cfg)
            self?.applyLanguage(cfg)
            self?.applyMenuBarIcon(cfg)
        }
        return m
    }()
    private var promptedForAccessibility = false
    private var wizardAutoShown = false

    // MARK: - Other gesture tools

    /// Gesture tools that also take over the right button. Running both re-posts each other's
    /// clicks (BetterAndBetter strips our replay marker → endless right-click loop in WeChat).
    static let conflictingBundleIDs = ["cn.better365.BetterAndBetter"]

    static func conflicts(in running: [String?]) -> [String] {
        conflictingBundleIDs.filter { running.contains($0) }
    }

    private var conflictAlertShown = false

    private func watchForConflictingApps() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkConflicts() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if AppDelegate.conflictingBundleIDs.contains(id ?? "") { self?.conflictAlertShown = false; self?.checkConflicts() }
        }
    }

    private func checkConflicts() {
        let apps = NSWorkspace.shared.runningApplications
        guard !conflictAlertShown, !AppDelegate.conflicts(in: apps.map(\.bundleIdentifier)).isEmpty else { return }
        conflictAlertShown = true
        Log.write("conflict: BetterAndBetter is running")
        let a = NSAlert()
        a.messageText = L("BetterAndBetter 正在运行")
        a.informativeText = L("它和 GestureKit 都会接管右键和鼠标手势，同时运行会互相干扰（例如微信里右键没反应、变卡）。建议退出 BetterAndBetter。")
        a.addButton(withTitle: L("退出 BetterAndBetter"))
        a.addButton(withTitle: L("暂时不管"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for app in apps where AppDelegate.conflictingBundleIDs.contains(app.bundleIdentifier ?? "") { app.terminate() }
        Log.write("conflict: asked BetterAndBetter to quit")
    }

    /// Cursor hint for a gesture that ran nothing (nil when it ran).
    static func hint(for r: GestureRecord) -> String? {
        switch r.via {
        case .none:     return L("未识别")
        case .unsure:   return L("把握不足，未执行：%@", r.action)
        case .rejected: return L("已按你的反馈忽略：%@", r.action)
        default:        return nil
        }
    }

    /// Run on the engine's (tap) thread.
    private func onEngine(_ block: @escaping (GestureEngine) -> Void) {
        guard let engine else { return }
        TapThread.shared.perform { block(engine) }
    }

    private func setEngineConfig(_ cfg: Config) {
        config = cfg
        onEngine { $0.config = cfg }
    }

    /// Two copies would both handle every chord (double actions, one swallowing
    /// the other's button-ups). The newest launch wins: quit the older ones.
    private func takeOverFromOtherInstances() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        where other.processIdentifier != me {
            Log.write("another GestureKit is running (pid \(other.processIdentifier)); asking it to quit")
            if !other.terminate() { other.forceTerminate(); continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !other.isTerminated { other.forceTerminate() }
            }
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        takeOverFromOtherInstances()
        var config = Config.loadOrCreate()
        let reconciled = GestureHistory.reconcile(config, with: GestureHistory.shared.records)
        if GestureHistory.learnedCount(reconciled) != GestureHistory.learnedCount(config) {
            Log.write("learning: dropped samples whose history rating now says another gesture")
            ConfigIO.backup(tag: "before-reconcile")
            Config.save(reconciled)
            config = reconciled
        }
        L10n.setting = config.language
        self.config = config
        engine = GestureEngine(config: config)
        engine.warmUp()                  // screen layout + front app, read here on the main thread
        engine.engineQueue = { TapThread.shared.perform($0) }
        engine.strokeInterval = 1.0 / 60
        engine.smoother = SmoothScroller()
        MainStallWatch.start()

        setupStatusItem()
        applyMenuBarIcon(config)
        // Shape recognition: off the tap thread, on a snapshot of the rules.
        engine.deferWork = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
        // Called on the tap thread (≤ 60/s while drawing); the trail is drawn on the main thread.
        engine.onChordStroke = { [weak self] points, finished in
            DispatchQueue.main.async {
                guard let self else { return }
                let trail = self.config.trail ?? TrailConfig()
                guard trail.enabled else { return }
                GestureTrail.shared.update(points, finished: finished, config: trail)
            }
        }
        GestureTrail.shared.prepare()
        // Every gesture → 手势记录; ones that ran nothing get a short hint at the cursor.
        engine.onRecognized = { [weak self] result, points, app in
            let record = GestureRecord(time: Date(), app: app, points: GestureHistory.compact(points),
                                       gestureID: result.gestureID, score: result.score, via: result.via,
                                       action: result.spec.flatMap(ActionCatalog.hudText(for:)) ?? "")
            DispatchQueue.main.async {
                GestureHistory.shared.add(record)
                guard let self, self.config.showUnrecognized ?? true,
                      let hint = AppDelegate.hint(for: record) else { return }
                HUD.shared.show(hint, duration: 0.9)
            }
        }
        Actions.presenter = { [weak self] spec in
            guard let cfg = self?.config, cfg.showHUD ?? true,
                  spec.type != "volume",                     // shows the new level instead (levelPresenter)
                  let text = ActionCatalog.hudText(for: spec) else { return }
            HUD.shared.show(text, duration: cfg.hudDuration ?? 0.5)
        }
        Actions.levelPresenter = { [weak self] text in
            guard let cfg = self?.config, cfg.showHUD ?? true else { return }
            HUD.shared.show(text, duration: max(cfg.hudDuration ?? 0.5, 0.8))
        }
        if CommandLine.arguments.contains("--prefs") || CommandLine.arguments.contains("--prefs-page") {
            let args = CommandLine.arguments
            let pageName = args.firstIndex(of: "--prefs-page").flatMap { i in
                i + 1 < args.count ? args[i + 1] : nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if let pageName, let p = PrefPage.allCases.first(where: { $0.zhTitle == pageName || $0.title == pageName || "\($0)" == pageName }) {
                    self.prefModel.page = p
                }
                self.openPreferences()
            }
        }
        if CommandLine.arguments.contains("--tap-isolation-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                TapIsolationTest.run { code in Log.flush(); exit(code) }
            }
        }
        if CommandLine.arguments.contains("--ui-click-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.openPreferences()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    PrefsClickTest.run(model: self.prefModel) { failures in
                        Log.flush()
                        exit(Int32(min(failures, 100)))
                    }
                }
            }
        }
        startEngine()
        watchForConflictingApps()
        Actions.shared.startTracking()
        // 动作在后台队列执行：事件 tap 回调（主线程，含每次鼠标移动）从不等待动作
        Actions.shared.executor = { Actions.workQueue.async(execute: $0) }
        NotificationCenter.default.addObserver(forName: Actions.openPreferencesNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.openPreferences()
        }
        if CommandLine.arguments.contains("--permission-wizard") {
            // 调试：直接打开向导（不自动关闭），便于人工查看界面
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPermissionWizard(autoClose: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
    }

    // MARK: - Engine / tap

    private func startEngine() {
        let trusted = AXIsProcessTrusted()
        Log.write("startEngine: accessibilityTrusted=\(trusted)")
        if !tap.start(engine: engine) {
            Log.write("event tap creation FAILED (no Accessibility/Input Monitoring permission)")
            tapFailed()
        } else {
            Log.write("event tap started")
        }
    }

    /// Non-modal failure path: mark the menu bar, open the permission wizard
    /// (once per launch), then retry until the user grants Accessibility.
    private func tapFailed() {
        statusItem.button?.title = "◈!"
        statusItem.button?.toolTip = L("GestureKit：等待「辅助功能」权限")
        let d = PermissionPolicy.onTapFailure(trusted: AXIsProcessTrusted(),
                                              alreadyPrompted: promptedForAccessibility,
                                              wizardAutoShown: wizardAutoShown)
        if d.openWizard {
            wizardAutoShown = true
            showPermissionWizard()
        }
        if d.systemPrompt {
            // 系统提示整个进程最多一次（它会把 GestureKit 加进辅助功能列表）
            promptedForAccessibility = true
            PromptForAccessibilityIfNeeded()
        }
        if d.scheduleRetry && retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                self?.tryStartTap()
            }
        }
    }

    /// 唯一的「重新启动 tap」入口：5s 重试计时器和向导授权回调都走这里。
    /// 已在运行则什么也不做，避免重复 start。
    private func tryStartTap() {
        if !tap.isRunning {
            guard tap.start(engine: engine) else { return }
            Log.write("event tap started (after permission granted)")
        }
        retryTimer?.invalidate()
        retryTimer = nil
        statusItem.button?.title = "◈"
        statusItem.button?.toolTip = "GestureKit"
        rebuildMenu()
    }

    private func showPermissionWizard(autoClose: Bool = true) {
        PermissionWizardController.show(autoClose: autoClose) { [weak self] in
            self?.tryStartTap()
        }
    }

    // MARK: - Language

    /// 配置里的语言变了：更新 L10n 并重建菜单（设置窗口、HUD 自动跟随）。
    private func applyLanguage(_ cfg: Config) {
        let before = L10n.current
        L10n.setting = cfg.language
        guard L10n.current != before else { return }
        Log.write("language: \(L10n.current.rawValue)")
        rebuildMenu()
    }

    // MARK: - Status item

    private func applyMenuBarIcon(_ cfg: Config) {
        statusItem.isVisible = cfg.showMenuBarIcon ?? true
    }

    /// Icon hidden → opening the app again (Finder / Launchpad / `open -a`) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◈"
        statusItem.button?.toolTip = "GestureKit"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let enabled = NSMenuItem(title: L("启用"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = (config.enabled && !paused) ? .on : .off
        menu.addItem(enabled)

        let prefs = NSMenuItem(title: L("偏好设置…"), action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let open = NSMenuItem(title: L("打开配置文件…"), action: #selector(openConfig), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let reload = NSMenuItem(title: L("重新加载配置"), action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let perm = NSMenuItem(title: L("授予辅助功能权限…"), action: #selector(checkPermission), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        let login = NSMenuItem(title: L("开机自启"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("退出 GestureKit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        paused.toggle()
        let p = paused
        onEngine { $0.paused = p }
        rebuildMenu()
    }

    @objc private func openPreferences() {
        prefModel.config = config
        PreferencesWindowController.show(model: prefModel)
    }

    @objc private func openConfig() {
        _ = Config.loadOrCreate()   // make sure the file exists
        NSWorkspace.shared.open(Config.configURL)
    }

    @objc private func reloadConfig() {
        setEngineConfig(Config.loadOrCreate())
        prefModel.config = config
        L10n.setting = config.language
        rebuildMenu()
        notify(L("配置已重新加载"))
    }

    @objc private func checkPermission() {
        switch PermissionPolicy.menu(trusted: AXIsProcessTrusted()) {
        case .alreadyGranted: notify(L("辅助功能权限已授权"))
        case .openWizard:     showPermissionWizard()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Login item

    private var loginItemEnabled: Bool { LoginItem.isEnabled }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            notify(L("登录项设置失败：%@", error.localizedDescription))
        }
        rebuildMenu()
    }

    // MARK: - Helpers

    private func notify(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: L("好"))
        alert.runModal()
    }
}

private func PromptForAccessibilityIfNeeded() {
    guard !AXIsProcessTrusted() else { return }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

/// Launch at login (SMAppService), shared by the menu and 通用设置.
enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func set(_ on: Bool) throws {
        guard #available(macOS 13.0, *), on != isEnabled else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
