import Cocoa

// 中键 / 侧键 与组合手势的自检（引擎层，不涉及设备枚举）。
extension SelfTest {
    static func buttonChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }

        // 与 main.swift 的 makeEngine() 相同：固定 ruleset，不发真实滚轮事件
        func makeEngine(_ config: Config = .defaultConfig) -> GestureEngine {
            let e = GestureEngine(config: config)
            e.rulesetOverride = "selftest.none"
            e.isButtonHeld = { _ in true }
            return e
        }
        func ev(_ type: CGEventType, _ p: CGPoint, button: Int64) -> CGEvent {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                            mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)!
            e.setIntegerValueField(.mouseEventButtonNumber, value: button)
            return e
        }
        let p0 = CGPoint(x: 600, y: 500)

        // 收集本套件里触发的动作（结束时恢复 main.swift 的 observer）
        var fired: [ActionSpec] = []
        let savedObserver = Actions.observer
        let savedDryRun = Actions.dryRun
        Actions.dryRun = true
        Actions.observer = { fired.append($0) }
        defer { Actions.observer = savedObserver; Actions.dryRun = savedDryRun }

        // MARK: 事件掩码包含中键/侧键
        do {
            let m = EventTap.eventMask
            let need: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                       .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
            check("buttons: tap mask includes otherMouse down/up/dragged",
                  need.allSatisfy { m & (1 << $0.rawValue) != 0 })
        }

        // MARK: 单独按中键/侧键 → 放行，不触发动作
        for button: Int64 in [2, 3, 4, 7] {
            fired.removeAll()
            let e = makeEngine()
            let d = e.handle(type: .otherMouseDown, event: ev(.otherMouseDown, p0, button: button))
            let g = e.handle(type: .otherMouseDragged,
                             event: ev(.otherMouseDragged, CGPoint(x: 700, y: 500), button: button))
            let u = e.handle(type: .otherMouseUp, event: ev(.otherMouseUp, CGPoint(x: 700, y: 500), button: button))
            // 之后的普通左键单击也必须放行（没有残留按键状态）
            let ld = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, p0, button: 0))
            let lu = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, p0, button: 0))
            check("buttons: lone button \(button + 1) passes through",
                  d != nil && g != nil && u != nil && ld != nil && lu != nil && fired.isEmpty)
        }

        // MARK: 左键按住 + 侧键 → 组合手势：侧键及之后的拖动/抬起被吞
        do {
            fired.removeAll()
            let e = makeEngine()
            let ld = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, p0, button: 0))
            let sd = e.handle(type: .otherMouseDown, event: ev(.otherMouseDown, p0, button: 3))
            var dragSwallowed = true
            for x in stride(from: 590, through: 480, by: -10) {
                let r = e.handle(type: .leftMouseDragged,
                                 event: ev(.leftMouseDragged, CGPoint(x: x, y: 500), button: 0))
                if r != nil { dragSwallowed = false }
            }
            let su = e.handle(type: .otherMouseUp, event: ev(.otherMouseUp, CGPoint(x: 480, y: 500), button: 3))
            _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, CGPoint(x: 480, y: 500), button: 0))
            check("buttons: left + side-4 chord swallows side down/drag/up",
                  ld != nil && sd == nil && dragSwallowed && su == nil)
            check("buttons: left + side-4 chord ← fires ⌘[ 后退",
                  fired.first?.type == "shortcut" && fired.first?.keyCode == 33,
                  "got \(fired.first.map { "\($0.type)/\($0.keyCode ?? -1)" } ?? "nil")")
        }

        // MARK: 中键 + 侧键（无左右键）也是组合手势
        do {
            fired.removeAll()
            let e = makeEngine()
            let md = e.handle(type: .otherMouseDown, event: ev(.otherMouseDown, p0, button: 2))
            let sd = e.handle(type: .otherMouseDown, event: ev(.otherMouseDown, p0, button: 4))
            for x in stride(from: 610, through: 720, by: 10) {
                _ = e.handle(type: .otherMouseDragged,
                             event: ev(.otherMouseDragged, CGPoint(x: x, y: 500), button: 2))
            }
            let su = e.handle(type: .otherMouseUp, event: ev(.otherMouseUp, CGPoint(x: 720, y: 500), button: 4))
            _ = e.handle(type: .otherMouseUp, event: ev(.otherMouseUp, CGPoint(x: 720, y: 500), button: 2))
            check("buttons: middle + side-5 chord → fires ⌘] 前进",
                  md != nil && sd == nil && su == nil
                    && fired.first?.type == "shortcut" && fired.first?.keyCode == 30)
        }

        return out
    }
}
