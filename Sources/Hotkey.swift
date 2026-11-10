import Carbon

/// 全局快捷键（Carbon RegisterEventHotKey）。不经过事件 tap，也不需要额外权限；
/// 回调在主线程。
final class Hotkey {

    /// 注册结果，便于提示「被占用」
    enum Status: Equatable { case ok, taken, failed(OSStatus) }

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    /// "GKHK"
    private static let signature: OSType = 0x474B_484B

    private var ref: EventHotKeyRef?
    private let id: UInt32
    let status: Status

    /// keyCode 用 kVK_*，modifiers 用 Carbon 的 cmdKey / controlKey / optionKey / shiftKey
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Hotkey.installHandler()
        id = Hotkey.nextID
        Hotkey.nextID += 1
        var r: EventHotKeyRef?
        let err = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Hotkey.signature, id: id),
                                      GetApplicationEventTarget(), 0, &r)
        status = Hotkey.status(for: err)
        if err == noErr {
            ref = r
            Hotkey.handlers[id] = handler
        }
    }

    deinit { unregister() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Hotkey.handlers[id] = nil
    }

    static func status(for err: OSStatus) -> Status {
        switch err {
        case noErr: return .ok
        case OSStatus(eventHotKeyExistsErr): return .taken
        default: return .failed(err)
        }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { Hotkey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
