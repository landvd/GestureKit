import Cocoa

// P2-14 权限向导 的自检。由负责该功能的人填写；不要在 main.swift 里加这部分断言。
// 只测纯逻辑与注入了 trust/时钟的 Model：不创建窗口、不弹系统提示、不打开系统设置。
extension SelfTest {
    static func permissionChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        typealias L = PermissionWizardLogic

        // 1. 状态机：未授权一直等待，无副作用
        do {
            var l = L()
            var effects: [L.Effect] = []
            for i in 0..<5 { effects += l.step(trusted: false, now: Double(i)) }
            check("perm: untrusted stays waiting, no effects", l.phase == .waiting && effects.isEmpty)
        }

        // 2. 授权 → startTap 一次 → 1.5s 后 close 一次 → 之后无副作用
        do {
            var l = L(closeDelay: 1.5)
            let seq: [(Bool, Double)] = [(false, 0), (false, 1), (true, 2), (true, 3), (true, 3.5), (true, 4), (true, 5)]
            var log: [(Double, [L.Effect])] = []
            for (t, now) in seq { log.append((now, l.step(trusted: t, now: now))) }
            let all = log.flatMap { $0.1 }
            check("perm: grant emits startTap exactly once", all.filter { $0 == .startTap }.count == 1
                  && log[2].1 == [.startTap])
            check("perm: no close before delay", log[3].1.isEmpty, "\(log[3].1)")
            check("perm: close after 1.5s", log[4].1 == [.close], "\(log[4].1)")
            check("perm: done is terminal", l.phase == .done && log[5].1.isEmpty && log[6].1.isEmpty
                  && all.filter { $0 == .close }.count == 1)
        }

        // 3. 已授权打开（如 --permission-wizard 或刚好授权）：第一次 tick 就 startTap
        do {
            var l = L()
            let e = l.step(trusted: true, now: 10)
            check("perm: trusted at open → startTap immediately", e == [.startTap] && l.phase == .granted)
        }

        // 4. autoClose=false（调试参数）：授权后不关闭
        do {
            var l = L(autoClose: false)
            var all: [L.Effect] = []
            for i in 0..<10 { all += l.step(trusted: true, now: Double(i)) }
            check("perm: autoClose off never closes", all == [.startTap] && l.phase == .granted)
        }

        // 5. 授权后又撤销：回到等待，不关闭；再次授权不重复 startTap
        do {
            var l = L(closeDelay: 1.5)
            var all: [L.Effect] = []
            all += l.step(trusted: true, now: 0)
            all += l.step(trusted: false, now: 1)
            let back = l.phase == .waiting
            all += l.step(trusted: false, now: 3)
            all += l.step(trusted: true, now: 4)
            all += l.step(trusted: true, now: 5)
            all += l.step(trusted: true, now: 5.6)
            check("perm: revoke returns to waiting, no duplicate startTap",
                  back && all == [.startTap, .close], "\(all)")
        }

        // 6. Model：注入 trust 序列与时钟，回调次数正确
        do {
            var trusted = false
            var now: TimeInterval = 100
            let m = PermissionWizardModel(trustProvider: { trusted }, clock: { now })
            var granted = 0, closed = 0, settings = 0
            m.onGranted = { granted += 1 }
            m.onClose = { closed += 1 }
            m.openSettings = { settings += 1 }
            m.revealApp = {}
            m.tick(); now += 1; m.tick(); now += 1
            let waitingOK = m.phase == .waiting && m.elapsed == 1 && granted == 0
            trusted = true
            m.tick()                 // t=102 granted
            now += 1; m.tick()       // 103
            now += 1; m.tick()       // 104 ≥ 1.5s → close
            now += 1; m.tick()
            check("perm: model waiting tracks elapsed", waitingOK)
            check("perm: model fires onGranted once, onClose once", granted == 1 && closed == 1 && m.phase == .done,
                  "granted=\(granted) closed=\(closed)")
            check("perm: model never opens settings on its own", settings == 0)
        }

        // 7. 策略：启动失败 / 菜单
        do {
            let p = PermissionPolicy.self
            let first = p.onTapFailure(trusted: false, alreadyPrompted: false, wizardAutoShown: false)
            let again = p.onTapFailure(trusted: false, alreadyPrompted: true, wizardAutoShown: true)
            let trustedFail = p.onTapFailure(trusted: true, alreadyPrompted: false, wizardAutoShown: false)
            check("perm: first tap failure opens wizard + one system prompt",
                  first == .init(openWizard: true, systemPrompt: true, scheduleRetry: true))
            check("perm: later failures never re-prompt or re-open",
                  again == .init(openWizard: false, systemPrompt: false, scheduleRetry: true))
            check("perm: trusted but tap failed → retry only",
                  trustedFail == .init(openWizard: false, systemPrompt: false, scheduleRetry: true))
            check("perm: menu untrusted opens wizard, trusted shows granted",
                  p.menu(trusted: false) == .openWizard && p.menu(trusted: true) == .alreadyGranted)
            let u = p.accessibilitySettingsURL.absoluteString
            check("perm: settings URL is x-apple.systempreferences Accessibility",
                  u.hasPrefix("x-apple.systempreferences:") && u.contains("Privacy_Accessibility"))
        }
        return out
    }
}
