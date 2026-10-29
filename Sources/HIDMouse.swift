import Cocoa
import IOKit.hid

// P2-12 IOHID 设备层。
//
// 权限取舍：这里只做「枚举 + 插拔监听」——IOHIDManagerSetDeviceMatching /
// CopyDevices / DeviceGetProperty / CopyMatchingElements 都不需要打开设备，
// 不会触发「输入监控」(kTCCServiceListenEvent) 弹窗。我们从不调用
// IOHIDManagerOpen / IOHIDDeviceOpen / RegisterInputValueCallback。
// 实时按键状态复用事件 tap 已拿到的鼠标事件（见 MouseButtonFeed），
// 所以 CGEvent 能看到的 2…N 键（mouseEventButtonNumber）都能显示；
// 只走 HID 厂商页的宏键暂不支持（需要输入监控权限）。

/// 一个鼠标类 HID 设备（鼠标 / 妙控鼠标 / 触控板）的只读描述。
struct HIDMouseInfo: Equatable, Identifiable {
    enum Kind: Int { case mouse = 0, magicMouse = 1, trackpad = 2 }

    var id: String
    var product: String
    var manufacturer: String
    var vendorID: Int?
    var productID: Int?
    /// IOHIDDevice 的原始 Transport 字符串（USB / Bluetooth / SPI …）
    var transport: String
    /// 报告描述符里的按键数（Button page 最大 usage）；0 = 未知
    var buttonCount: Int
    var builtIn: Bool
    var kind: Kind

    var transportText: String { HIDMouse.transportText(transport, builtIn: builtIn) }
    var productIDText: String { productID.map(HIDMouse.hex) ?? "—" }
    var vendorIDText: String { vendorID.map(HIDMouse.hex) ?? "—" }
    var buttonCountText: String { buttonCount > 0 ? L("%d 键", buttonCount) : "—" }
    var displayName: String { L("%@（%@）", product, transportText) }

    /// 厂商驱动常会接管侧键，CGEvent 就看不到了（原版也有这条提示）。
    var driverHint: String? {
        switch vendorID {
        case 0x046D: return L("罗技设备：若侧键无反应，可能已被 Logi Options+ 接管，可在其中把按键恢复为「默认/系统」。")
        case 0x1532: return L("雷蛇设备：若侧键无反应，可能已被 Razer Synapse 接管。")
        default: return nil
        }
    }
}

enum HIDMouse {

    /// 鼠标 + 指针（触控板的指针接口）两类 usage。
    static let matching: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
        [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
    ]

    static func hex(_ v: Int) -> String { String(format: "0x%04X (%d)", v, v) }

    static func transportText(_ raw: String, builtIn: Bool = false) -> String {
        switch raw.lowercased() {
        case "usb": return "USB"
        case "bluetooth": return L("蓝牙")
        case "bluetooth low energy", "bluetoothlowenergy", "ble": return L("蓝牙（低功耗）")
        case "spi", "i2c", "fifo": return L("内建")
        case "virtual": return L("虚拟设备")
        case "": return builtIn ? L("内建") : "—"
        default: return raw
        }
    }

    /// 纯函数：IOHIDDevice 属性字典 + Button usage 列表 → 设备描述（自检用）。
    static func parse(properties p: [String: Any], buttonUsages: [Int]) -> HIDMouseInfo {
        func str(_ k: String) -> String? {
            guard let s = p[k] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        func int(_ k: String) -> Int? { (p[k] as? NSNumber)?.intValue ?? (p[k] as? Int) }
        let product = str(kIOHIDProductKey) ?? L("未知设备")
        let transport = str(kIOHIDTransportKey) ?? ""
        let builtIn = (p[kIOHIDBuiltInKey] as? NSNumber)?.boolValue
            ?? ["spi", "i2c", "fifo"].contains(transport.lowercased())
        let vid = int(kIOHIDVendorIDKey)
        let pid = int(kIOHIDProductIDKey)
        let loc = int(kIOHIDLocationIDKey)
        let serial = str(kIOHIDSerialNumberKey)

        let lower = product.lowercased()
        let kind: HIDMouseInfo.Kind
        if lower.contains("trackpad") || lower.contains("触控板") { kind = .trackpad }
        else if lower.contains("magic mouse") || lower.contains("妙控鼠标") { kind = .magicMouse }
        else { kind = .mouse }

        let ident = loc.map { String($0) } ?? serial ?? product
        return HIDMouseInfo(
            id: "\(vid ?? 0):\(pid ?? 0):\(ident)",
            product: product,
            manufacturer: str(kIOHIDManufacturerKey) ?? "—",
            vendorID: vid, productID: pid,
            transport: transport,
            buttonCount: buttonUsages.filter { $0 > 0 && $0 <= 32 }.max() ?? 0,
            builtIn: builtIn, kind: kind)
    }

    /// 同一物理设备常暴露多个接口（Mouse + Pointer）→ 按 id 去重，按键数取大；
    /// 外接鼠标排前，触控板排后。
    static func merge(_ list: [HIDMouseInfo]) -> [HIDMouseInfo] {
        var byID: [String: HIDMouseInfo] = [:]
        for d in list {
            if var old = byID[d.id] {
                old.buttonCount = max(old.buttonCount, d.buttonCount)
                byID[d.id] = old
            } else {
                byID[d.id] = d
            }
        }
        return byID.values.sorted {
            ($0.kind.rawValue, $0.builtIn ? 1 : 0, $0.product, $0.id)
                < ($1.kind.rawValue, $1.builtIn ? 1 : 0, $1.product, $1.id)
        }
    }

    /// 设备页对应的默认设备：普通鼠标页选外接鼠标（触控板、妙控鼠标只用于区分，不再有设置页）。
    static func preferred(_ list: [HIDMouseInfo], kind: HIDMouseInfo.Kind?) -> HIDMouseInfo? {
        if let kind, let d = list.first(where: { $0.kind == kind }) { return d }
        return list.first
    }

    static func info(for dev: IOHIDDevice) -> HIDMouseInfo {
        var props: [String: Any] = [:]
        for k in [kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDVendorIDKey, kIOHIDProductIDKey,
                  kIOHIDTransportKey, kIOHIDLocationIDKey, kIOHIDSerialNumberKey, kIOHIDBuiltInKey] {
            if let v = IOHIDDeviceGetProperty(dev, k as CFString) { props[k] = v }
        }
        // 读报告描述符里的元素，不需要打开设备
        let match = [kIOHIDElementUsagePageKey: kHIDPage_Button] as CFDictionary
        let els = (IOHIDDeviceCopyMatchingElements(dev, match, IOOptionBits(kIOHIDOptionsTypeNone))
                   as? [IOHIDElement]) ?? []
        return parse(properties: props, buttonUsages: els.map { Int(IOHIDElementGetUsage($0)) })
    }

    static func devices(of mgr: IOHIDManager) -> [HIDMouseInfo] {
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return [] }
        return merge(set.map(info(for:)))
    }

    /// 一次性枚举（不打开设备、不调度 run loop）。
    static func enumerate() -> [HIDMouseInfo] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)
        return devices(of: mgr)
    }

    /// 「输入监控」权限现状（IOHIDCheckAccess 只查询，不弹窗）。
    static var inputMonitoringText: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return L("已授权")
        case kIOHIDAccessTypeDenied: return L("未授权")
        default: return L("未询问")
        }
    }
}

/// 监听鼠标类设备插拔（不打开设备）。设备列表变化时发 `changed` 通知。
final class HIDMouseMonitor {
    static let shared = HIDMouseMonitor()
    static let changed = Notification.Name("GestureKit.hidMiceChanged")

    private var manager: IOHIDManager?
    private var refreshPending = false
    private(set) var devices: [HIDMouseInfo] = []

    var isRunning: Bool { manager != nil }

    func start() {
        guard manager == nil else { refresh(); return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, HIDMouse.matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDMouseMonitor>.fromOpaque(ctx).takeUnretainedValue().scheduleRefresh()
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            Unmanaged<HIDMouseMonitor>.fromOpaque(ctx).takeUnretainedValue().scheduleRefresh()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        manager = mgr
        refresh()
    }

    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        manager = nil
    }

    /// 一次插拔会连发多个 match/remove 回调（多接口），合并成一次刷新。
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    /// Reading each device's elements (button count) takes ~10–80 ms and goes through
    /// the system's input-access check, so it runs off the main thread: the main thread
    /// also runs the event tap, and blocking it froze the cursor while the page opened.
    private static let queue = DispatchQueue(label: "gesturekit.hid", qos: .userInitiated)

    func refresh() {
        guard let mgr = manager, let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }
        HIDMouseMonitor.queue.async { [weak self] in
            let now = HIDMouse.merge(set.map(HIDMouse.info(for:)))
            DispatchQueue.main.async {
                guard let self, self.manager != nil, now != self.devices else { return }
                let added = Set(now.map(\.id)).subtracting(self.devices.map(\.id)).count
                let removed = Set(self.devices.map(\.id)).subtracting(now.map(\.id)).count
                self.devices = now
                Log.write("hid: \(now.count) pointing device(s) (+\(added) −\(removed))")
                NotificationCenter.default.post(name: HIDMouseMonitor.changed, object: self)
            }
        }
    }
}

// MARK: - 按键号与实时按键状态

enum MouseButtons {
    /// CGEvent 按键号（0 基）→ 中文名：0 左键 / 1 右键 / 2 中键 / n → 第 n+1 键
    static func name(_ button: Int64) -> String {
        switch button {
        case 0: return L("左键")
        case 1: return L("右键")
        case 2: return L("中键")
        default: return L("第 %d 键", Int(button + 1))
        }
    }

    static func stateText(_ button: Int64, down: Bool) -> String {
        down ? L("%@按下", name(button)) : L("%@松开", name(button))
    }

    /// 鼠标按键事件 → (按键号, 是否按下)；其它事件返回 nil。
    static func decode(type: CGEventType, event: CGEvent) -> (button: Int64, down: Bool)? {
        switch type {
        case .leftMouseDown: return (0, true)
        case .leftMouseUp: return (0, false)
        case .rightMouseDown: return (1, true)
        case .rightMouseUp: return (1, false)
        case .otherMouseDown: return (event.getIntegerValueField(.mouseEventButtonNumber), true)
        case .otherMouseUp: return (event.getIntegerValueField(.mouseEventButtonNumber), false)
        default: return nil
        }
    }
}

/// 事件 tap → 设置页「按键识别」的按键广播。只有设置页打开该页时才 active，
/// 平时 tap 回调里只多一次布尔判断。只观察，从不改变事件。
enum MouseButtonFeed {
    static let notification = Notification.Name("GestureKit.mouseButton")
    /// 设置页「按键识别」可见时为 true
    static var isActive = false
    /// EventTap 正在运行（否则设置页退回到窗口内的 NSEvent 本地监听）
    static var tapRunning = false

    /// 是否应广播这个事件；合成事件（我们自己发的中键等）不算。
    static func payload(type: CGEventType, event: CGEvent) -> (button: Int64, down: Bool)? {
        guard isActive, !Actions.isSynthetic(event) else { return nil }
        return MouseButtons.decode(type: type, event: event)
    }

    static func publish(type: CGEventType, event: CGEvent) {
        guard let p = payload(type: type, event: event) else { return }
        // 异步投递：不在 tap 回调里跑 SwiftUI 更新，避免 tap 超时
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: notification, object: nil,
                                            userInfo: ["button": p.button, "down": p.down])
        }
    }
}

/// 「手动适配」：用户依次按下除左键外的各个键，记录实际上报的按键号。
/// 左键不记录（用户要用它点「完成」）。结果只展示，不写入配置。
struct ButtonAdaptation: Equatable {
    private(set) var recorded: [Int64] = []

    /// 记录一次按下；返回是否为新键。
    @discardableResult
    mutating func record(_ button: Int64, down: Bool) -> Bool {
        guard down, button != 0, !recorded.contains(button) else { return false }
        recorded.append(button)
        return true
    }

    var lines: [String] {
        recorded.enumerated().map { i, b in
            L("第 %d 个：按键号 %d → %@", i + 1, Int(b), MouseButtons.name(b))
        }
    }

    /// 识别到的键总数（含左键）
    var totalButtons: Int { recorded.count + 1 }

    func summary(expected: Int) -> String {
        var s = L("共识别 %d 个键（含左键）", totalButtons)
        if expected > totalButtons {
            s += L("；设备声明 %d 个键，其余键可能被厂商驱动占用或只经 HID 厂商页上报", expected)
        }
        return s
    }
}
