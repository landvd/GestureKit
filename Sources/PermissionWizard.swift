import Cocoa
import SwiftUI
import ApplicationServices

// P2-14 权限向导：没有「辅助功能」权限时给出图文步骤 + 实时状态。
// 只读取授权状态、只用 URL 打开系统设置页面；绝不替用户修改任何设置。
//
// 结构：
//   PermissionPolicy       纯逻辑：启动失败 / 菜单点击时该做什么
//   PermissionWizardLogic  纯逻辑状态机：trusted 序列 → 阶段 + 副作用（启动 tap / 关闭）
//   PermissionWizardModel  ObservableObject，注入 trust 提供者与时钟，1s 轮询
//   PermissionWizardView   SwiftUI 界面
//   PermissionWizardController  NSWindow + NSHostingView

// MARK: - Policy (pure)

enum PermissionPolicy {
    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let automationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    struct TapFailureDecision: Equatable {
        var openWizard: Bool
        var systemPrompt: Bool
        var scheduleRetry: Bool
    }

    /// Event tap 创建失败时的处理。
    /// - 未授权：首次自动打开向导；系统提示整个进程最多一次。
    /// - 已授权但 tap 仍失败（例如输入监控问题）：不打扰，只重试。
    static func onTapFailure(trusted: Bool, alreadyPrompted: Bool,
                             wizardAutoShown: Bool) -> TapFailureDecision {
        if trusted {
            return TapFailureDecision(openWizard: false, systemPrompt: false, scheduleRetry: true)
        }
        return TapFailureDecision(openWizard: !wizardAutoShown,
                                  systemPrompt: !alreadyPrompted,
                                  scheduleRetry: true)
    }

    enum MenuDecision: Equatable { case alreadyGranted, openWizard }

    /// 菜单「授予辅助功能权限…」。
    static func menu(trusted: Bool) -> MenuDecision {
        trusted ? .alreadyGranted : .openWizard
    }
}

// MARK: - State machine (pure)

struct PermissionWizardLogic {
    enum Phase: Equatable { case waiting, granted, done }
    enum Effect: Equatable { case startTap, close }

    var closeDelay: TimeInterval = 1.5
    /// false：调试参数 `--permission-wizard` 打开时不自动关闭，方便人工查看。
    var autoClose: Bool = true

    private(set) var phase: Phase = .waiting
    private(set) var grantedAt: TimeInterval?
    private(set) var tapRequested = false

    init(closeDelay: TimeInterval = 1.5, autoClose: Bool = true) {
        self.closeDelay = closeDelay
        self.autoClose = autoClose
    }

    /// 喂一次轮询结果。`startTap` 在整个向导生命周期内最多发一次；
    /// `close` 在授权后经过 `closeDelay` 发一次，之后不再产生任何副作用。
    mutating func step(trusted: Bool, now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        switch phase {
        case .done:
            return []
        case .waiting:
            guard trusted else { return [] }
            phase = .granted
            grantedAt = now
            if !tapRequested {
                tapRequested = true
                effects.append(.startTap)
            }
        case .granted:
            if !trusted {
                // 授权后又被撤销：回到等待，但不会再次请求 start（AppDelegate 的重试计时器兜底）
                phase = .waiting
                grantedAt = nil
                return []
            }
        }
        if phase == .granted, autoClose, let t = grantedAt, now - t >= closeDelay - 1e-9 {
            phase = .done
            effects.append(.close)
        }
        return effects
    }
}

// MARK: - Model

final class PermissionWizardModel: ObservableObject {
    @Published private(set) var phase: PermissionWizardLogic.Phase = .waiting
    @Published private(set) var elapsed: Int = 0

    var trustProvider: () -> Bool
    var clock: () -> TimeInterval
    /// 授权成功（每个向导最多一次）→ 由 AppDelegate 启动事件 tap。
    var onGranted: () -> Void = {}
    /// 自动关闭时机到达。
    var onClose: () -> Void = {}
    /// 界面按钮动作（可注入，自检里替换成空操作）。
    var openSettings: () -> Void = { NSWorkspace.shared.open(PermissionPolicy.accessibilitySettingsURL) }
    var revealApp: () -> Void = { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }

    private var logic: PermissionWizardLogic
    private var startedAt: TimeInterval
    private var timer: Timer?

    init(trustProvider: @escaping () -> Bool = { AXIsProcessTrusted() },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         autoClose: Bool = true, closeDelay: TimeInterval = 1.5) {
        self.trustProvider = trustProvider
        self.clock = clock
        self.logic = PermissionWizardLogic(closeDelay: closeDelay, autoClose: autoClose)
        self.startedAt = clock()
    }

    var autoClose: Bool { logic.autoClose }

    /// 当前 App 包路径（用于界面展示）。
    var bundlePath: String { Bundle.main.bundleURL.path }

    /// 执行一次检测。返回本次产生的副作用（便于测试）。
    @discardableResult
    func tick() -> [PermissionWizardLogic.Effect] {
        let now = clock()
        let effects = logic.step(trusted: trustProvider(), now: now)
        phase = logic.phase
        elapsed = max(0, Int(now - startedAt))
        for e in effects {
            switch e {
            case .startTap:
                onGranted()
            case .close:
                onClose()
            }
        }
        return effects
    }

    func startPolling() {
        stopPolling()
        tick()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - View

struct PermissionWizardView: View {
    @ObservedObject var model: PermissionWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            card(L("为什么需要「辅助功能」权限"), symbol: "hand.raised.fill", tint: UI.accent) {
                Text(L("GestureKit 需要监听鼠标按键、拖动与滚轮来识别手势，并通过辅助功能接口移动、缩放、全屏窗口。没有这项权限，手势不会生效。GestureKit 不联网、不收集任何数据。"))
                    .font(.system(size: 13))
                    .foregroundColor(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            card(L("授权步骤"), symbol: "list.number", tint: UI.accent) {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, L("点击下方「打开系统设置」，进入「隐私与安全性 → 辅助功能」。"))
                    step(2, L("在列表中找到 GestureKit，打开右侧开关（可能需要输入登录密码）。"))
                    step(3, L("如果列表里已有 GestureKit 但开关打开后仍不生效（重新编译或更新后常见）：选中旧条目点「−」删除，再点「+」添加 /Applications/GestureKit.app，或点「在访达中显示 GestureKit」后把它拖进列表。"))
                    step(4, L("授权完成后无需重启，本窗口会自动检测并关闭。"))
                }
                HStack(spacing: 12) {
                    Button(action: { model.openSettings() }) {
                        Label(L("打开系统设置"), systemImage: "gearshape")
                    }
                    .keyboardShortcut(.defaultAction)
                    Button(action: { model.revealApp() }) {
                        Label(L("在访达中显示 GestureKit"), systemImage: "folder")
                    }
                    Spacer()
                }
                .padding(.top, 4)
                Text(L("当前程序位置：%@", model.bundlePath))
                    .font(.system(size: 11))
                    .foregroundColor(UI.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            card(L("可选：自动化（AppleScript）"), symbol: "applescript", tint: UI.secondary) {
                Text(L("只有当你在动作里使用 AppleScript 控制其它 App 时才需要。首次运行这类脚本时系统会询问是否允许，按需同意即可；之后可在「隐私与安全性 → 自动化」中管理。"))
                    .font(.system(size: 12))
                    .foregroundColor(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status
        }
        .padding(28)
        .frame(width: 600)
        .background(UI.windowBG)
    }

    private var header: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(UI.accent)
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: "lock.shield")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("授予 GestureKit「辅助功能」权限")).font(.system(size: 18, weight: .bold))
                Text(L("只需一次设置，鼠标手势即可开始工作")).font(.system(size: 12)).foregroundColor(UI.secondary)
            }
            Spacer()
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            if model.phase == .waiting {
                Image(systemName: "hourglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(UI.secondary)
                Text(L("正在等待授权…（每秒自动检测，已等待 %d 秒）", model.elapsed))
                    .font(.system(size: 13))
                    .foregroundColor(UI.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(UI.ok)
                Text(model.autoClose ? L("已获得辅助功能权限，手势已启用。窗口即将关闭。") : L("已获得辅助功能权限，手势已启用。"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(UI.ok)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous).fill(UI.cardBG))
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(UI.accent)
                .frame(width: 20, height: 20)
                .overlay(Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundColor(.white))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 与设置窗口 card(...) 同风格（那边是 private，这里自写一份）
    private func card<C: View>(_ title: String, symbol: String, tint: Color,
                               @ViewBuilder body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous).fill(UI.cardBG))
    }
}

// MARK: - Window controller

final class PermissionWizardController: NSWindowController, NSWindowDelegate {
    private static var shared: PermissionWizardController?
    private var model: PermissionWizardModel?

    static var isShowing: Bool { shared != nil }

    /// 打开（或前置）向导。`onGranted` 在授权成功时调用一次。
    static func show(autoClose: Bool = true, onGranted: @escaping () -> Void) {
        if let w = shared {
            w.model?.onGranted = {
                Log.write("permission wizard: accessibility granted")
                onGranted()
            }
            w.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = PermissionWizardModel(autoClose: autoClose)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = L("GestureKit 权限向导")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: PermissionWizardView(model: model))
        win.setContentSize(win.contentView?.fittingSize ?? NSSize(width: 600, height: 640))
        win.center()
        let wc = PermissionWizardController(window: win)
        wc.model = model
        win.delegate = wc
        model.onGranted = {
            Log.write("permission wizard: accessibility granted")
            onGranted()
        }
        model.onClose = { [weak wc] in wc?.close() }
        shared = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.write("permission wizard opened (autoClose=\(autoClose))")
        model.startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopPolling()
        model = nil
        PermissionWizardController.shared = nil
        Log.write("permission wizard closed")
    }
}
