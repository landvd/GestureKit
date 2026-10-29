import Cocoa
import IOKit.hid

// P2-12 IOHID 设备层 的自检。由负责该功能的人填写；不要在 main.swift 里加这部分断言。
extension SelfTest {
    static func hidChecks() -> [SelfTestCheck] {
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

        // MARK: 按键号 → 中文名
        check("hid: button names 0…7",
              (0...7).map { MouseButtons.name(Int64($0)) }
                == ["左键", "右键", "中键", "第 4 键", "第 5 键", "第 6 键", "第 7 键", "第 8 键"])
        check("hid: button state text",
              MouseButtons.stateText(0, down: false) == "左键松开"
                && MouseButtons.stateText(4, down: true) == "第 5 键按下")

        // MARK: 事件 → (按键号, 按下)
        do {
            let l = MouseButtons.decode(type: .leftMouseDown, event: ev(.leftMouseDown, p0, button: 0))
            let r = MouseButtons.decode(type: .rightMouseUp, event: ev(.rightMouseUp, p0, button: 1))
            let s = MouseButtons.decode(type: .otherMouseDown, event: ev(.otherMouseDown, p0, button: 3))
            let k = MouseButtons.decode(type: .keyDown,
                                        event: CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!)
            check("hid: decode left/right/side/key",
                  l?.button == 0 && l?.down == true && r?.button == 1 && r?.down == false
                    && s?.button == 3 && s?.down == true && k == nil)
        }

        // MARK: 按键广播只在设置页打开时生效，且不广播合成事件
        do {
            let saved = MouseButtonFeed.isActive
            let side = ev(.otherMouseDown, p0, button: 4)
            MouseButtonFeed.isActive = false
            let off = MouseButtonFeed.payload(type: .otherMouseDown, event: side)
            MouseButtonFeed.isActive = true
            let on = MouseButtonFeed.payload(type: .otherMouseDown, event: side)
            let synth = ev(.otherMouseDown, p0, button: 2)
            synth.setIntegerValueField(.eventSourceUserData, value: Actions.syntheticMarker)
            let synthP = MouseButtonFeed.payload(type: .otherMouseDown, event: synth)
            MouseButtonFeed.isActive = saved
            check("hid: button feed gated by page + skips synthetic",
                  off == nil && on?.button == 4 && on?.down == true && synthP == nil)
        }

        // MARK: 事件掩码包含中键/侧键
        do {
            let m = EventTap.eventMask
            let need: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                       .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .mouseMoved]
            check("hid: tap mask includes otherMouse down/up/dragged",
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
            check("hid: lone \(MouseButtons.name(button)) passes through",
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
            check("hid: left + side-4 chord swallows side down/drag/up",
                  ld != nil && sd == nil && dragSwallowed && su == nil)
            check("hid: left + side-4 chord ← fires ⌘]",
                  fired.first?.type == "shortcut" && fired.first?.keyCode == 30,
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
            check("hid: middle + side-5 chord → fires ⌘[",
                  md != nil && sd == nil && su == nil
                    && fired.first?.type == "shortcut" && fired.first?.keyCode == 33)
        }

        // MARK: 设备属性解析
        do {
            let logi = HIDMouse.parse(properties: [
                kIOHIDProductKey: "MX Master 3S", kIOHIDManufacturerKey: "Logitech",
                kIOHIDVendorIDKey: NSNumber(value: 0x046D), kIOHIDProductIDKey: NSNumber(value: 0xB034),
                kIOHIDTransportKey: "Bluetooth Low Energy", kIOHIDLocationIDKey: NSNumber(value: 1234),
            ], buttonUsages: [1, 2, 3, 4, 5, 6, 7, 8])
            check("hid: parse external BLE mouse",
                  logi.product == "MX Master 3S" && logi.manufacturer == "Logitech"
                    && logi.vendorID == 0x046D && logi.productIDText == "0xB034 (45108)"
                    && logi.transportText == "蓝牙（低功耗）" && logi.buttonCount == 8
                    && logi.kind == .mouse && !logi.builtIn && logi.driverHint != nil,
                  "\(logi)")

            let tp = HIDMouse.parse(properties: [
                kIOHIDProductKey: "Apple Internal Keyboard / Trackpad", kIOHIDManufacturerKey: "Apple Inc.",
                kIOHIDVendorIDKey: NSNumber(value: 0x05AC), kIOHIDProductIDKey: NSNumber(value: 835),
                kIOHIDTransportKey: "SPI", kIOHIDLocationIDKey: NSNumber(value: 51),
            ], buttonUsages: [1, 2, 3])
            check("hid: parse built-in SPI trackpad",
                  tp.kind == .trackpad && tp.builtIn && tp.transportText == "内建"
                    && tp.buttonCount == 3 && tp.driverHint == nil)

            let mm = HIDMouse.parse(properties: [kIOHIDProductKey: "Magic Mouse", kIOHIDTransportKey: "Bluetooth"],
                                    buttonUsages: [1, 2])
            check("hid: parse Magic Mouse", mm.kind == .magicMouse && mm.transportText == "蓝牙")

            let empty = HIDMouse.parse(properties: [:], buttonUsages: [])
            check("hid: parse missing properties falls back",
                  empty.product == "未知设备" && empty.manufacturer == "—" && empty.productIDText == "—"
                    && empty.transportText == "—" && empty.buttonCountText == "—")

            // 同一设备的 Mouse + Pointer 两个接口去重，按键数取大；外接鼠标排前
            var tp2 = tp; tp2.buttonCount = 5
            let merged = HIDMouse.merge([tp, mm, tp2, logi])
            check("hid: merge dedupes interfaces and sorts mice first",
                  merged.count == 3 && merged[0].product == "MX Master 3S" && merged[1].kind == .magicMouse
                    && merged[2].kind == .trackpad && merged[2].buttonCount == 5,
                  merged.map(\.product).joined(separator: ","))
            check("hid: preferred device per page",
                  HIDMouse.preferred(merged, kind: .trackpad)?.kind == .trackpad
                    && HIDMouse.preferred(merged, kind: .magicMouse)?.kind == .magicMouse
                    && HIDMouse.preferred(merged, kind: nil)?.product == "MX Master 3S"
                    && HIDMouse.preferred([], kind: .mouse) == nil)
            let dm = DeviceInfo.mouse(from: logi)
            check("hid: DeviceInfo.Mouse from HID info",
                  dm.product == "MX Master 3S" && dm.transport == "蓝牙（低功耗）" && dm.buttons == "8 键")
        }

        // MARK: 手动适配
        do {
            var a = ButtonAdaptation()
            a.record(0, down: true)          // 左键：用于点按钮，不记录
            a.record(1, down: true)
            a.record(1, down: false)         // 松开不记录
            a.record(3, down: true)
            a.record(3, down: true)          // 重复不记录
            a.record(4, down: true)
            check("hid: manual adaptation records distinct non-left presses",
                  a.recorded == [1, 3, 4] && a.totalButtons == 4
                    && a.lines.last == "第 3 个：按键号 4 → 第 5 键"
                    && a.summary(expected: 8).contains("设备声明 8 个键")
                    && !a.summary(expected: 4).contains("设备声明"))
        }

        // MARK: PrefModel 按键状态（不启动监听）
        do {
            let m = PrefModel(config: .defaultConfig)
            m.handleButton(3, down: true)
            let downOK = m.lastButtonState == "第 4 键按下" && m.heldButtons == [3]
            m.beginAdaptation()
            m.handleButton(3, down: false)
            m.handleButton(2, down: true)
            m.finishAdaptation()
            check("hid: prefs live button state + adaptation",
                  downOK && m.heldButtons == [2] && m.adaptation == nil && m.adaptResult?.recorded == [2])
        }

        // MARK: 硬件只读调用：不崩溃、不打开设备（不依赖本机接了什么）
        do {
            let list = HIDMouse.enumerate()
            let cur = DeviceInfo.currentMouse()
            check("hid: enumerate is read-only and stable",
                  (list.isEmpty || cur != nil) && Set(list.map(\.id)).count == list.count,
                  "\(list.count) device(s): " + list.map(\.displayName).joined(separator: "; "))
            let mon = HIDMouseMonitor.shared
            let wasRunning = mon.isRunning
            mon.start()
            let started = mon.isRunning
            if !wasRunning { mon.stop() }
            check("hid: hot-plug monitor start/stop",
                  started && mon.isRunning == wasRunning, "input monitoring: \(HIDMouse.inputMonitoringText)")
        }

        return out
    }
}
