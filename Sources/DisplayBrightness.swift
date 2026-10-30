import Cocoa
import IOKit

/// Brightness for built-in and external displays.
///
/// Per display: DisplayServices when the display supports it (built-in panel,
/// Apple Studio Display / LG UltraFine), otherwise DDC/CI VCP 0x10 over the
/// Apple Silicon `IOAVService` I²C bus. DDC is slow (tens of ms per message),
/// so it runs on a background queue and never on the event-tap thread.
///
/// Target (`ActionSpec.op`): nil = display under the cursor, "external" = all
/// external displays, "builtin" = the built-in panel.
enum DisplayBrightness {

    struct DisplayRef: Equatable {
        var id: CGDirectDisplayID
        var builtin: Bool
        var frame: CGRect          // Cocoa coordinates
    }

    // MARK: - Entry

    static func adjust(by delta: Double, target: String?) {
        let displays = NSScreen.screens.compactMap { s -> DisplayRef? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return DisplayRef(id: id, builtin: CGDisplayIsBuiltin(id) != 0, frame: s.frame)
        }
        let targets = select(displays, cursor: NSEvent.mouseLocation, target: target)
        guard !targets.isEmpty else { Log.write("brightness: no display for target \(target ?? "cursor")"); return }

        var ddcTargets: [CGDirectDisplayID] = []
        for d in targets {
            if setWithDisplayServices(d.id, delta: delta) { continue }
            if d.builtin { Log.write("brightness: built-in display refused DisplayServices") }
            else { ddcTargets.append(d.id) }
        }
        guard !ddcTargets.isEmpty else { return }
        // All external displays (DisplayServices ones too) take part in matching,
        // so e.g. a Studio Display's AV service can't be mistaken for a DDC monitor.
        let externals = activeExternalDisplays()
        DDC.queue.async { DDC.adjust(targets: ddcTargets, externals: externals, delta: delta) }
    }

    /// External displays in `CGGetActiveDisplayList` order with their EDID identity.
    static func activeExternalDisplays() -> [ExternalDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map {
            ExternalDisplay(id: $0, identity: DisplayIdentity(vendor: CGDisplayVendorNumber($0),
                                                                model: CGDisplayModelNumber($0),
                                                                serial: CGDisplaySerialNumber($0)))
        }
    }

    /// Pure: which displays an action affects.
    static func select(_ displays: [DisplayRef], cursor: CGPoint, target: String?) -> [DisplayRef] {
        switch target {
        case "external": return displays.filter { !$0.builtin }
        case "builtin":  return displays.filter { $0.builtin }
        default:
            if let d = displays.first(where: { $0.frame.contains(cursor) }) { return [d] }
            return Array(displays.prefix(1))
        }
    }

    /// Pure: next raw value, moving at least one step so small ranges still change.
    static func step(current: Int, max: Int, delta: Double) -> Int {
        guard max > 0 else { return current }
        var amount = Int((Double(max) * delta).rounded())
        if amount == 0 { amount = delta < 0 ? -1 : 1 }
        return Swift.max(0, Swift.min(max, current + amount))
    }

    // MARK: - AV service ↔ display mapping (pure)

    /// EDID identity. `serial` 0 = the monitor doesn't report one.
    struct DisplayIdentity: Hashable, CustomStringConvertible {
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
        var description: String {
            "\(DisplayIdentity.pnpString(vendor))/\(String(format: "%04X", model))/\(serial == 0 ? "-" : String(serial))"
        }

        /// "GSM" → 0x1E6D (EDID bytes 8–9, same value `CGDisplayVendorNumber` returns).
        static func pnpVendor(_ s: String) -> UInt32? {
            let u = Array(s.uppercased().unicodeScalars)
            guard u.count == 3, u.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
            return u.reduce(0) { $0 << 5 | ($1.value - 64) }
        }

        static func pnpString(_ v: UInt32) -> String {
            let parts = [(v >> 10) & 31, (v >> 5) & 31, v & 31]
            guard parts.allSatisfy({ $0 >= 1 && $0 <= 26 }) else { return String(format: "%04X", v) }
            return String(String.UnicodeScalarView(parts.compactMap { Unicode.Scalar($0 + 64) }))
        }
    }

    struct ExternalDisplay: Equatable {
        var id: CGDirectDisplayID
        var identity: DisplayIdentity
    }

    struct ServiceMatch: Equatable {
        enum Basis: String { case single, serial, vendorModel = "vendor+model", order = "order" }
        var service: Int                 // index into the service list
        var display: CGDirectDisplayID
        var basis: Basis
        /// Not proven by EDID data (identical monitors or unknown attributes) — logged as 「推断」.
        var inferred: Bool { basis == .order }
    }

    /// Pure: pair AV services (identity read from the framebuffer next to each, nil
    /// if unknown; registry order) with external CG displays (`CGGetActiveDisplayList`
    /// order). Services left out have no trustworthy match; callers fall back.
    ///  1. one service + one display → that's it
    ///  2. vendor + model + non-zero serial equal
    ///  3. vendor + model equal; several identical monitors are paired in order (inferred)
    ///  4. services with unknown identity ↔ leftover displays, in order, only if counts agree (inferred)
    static func matchServices(_ services: [DisplayIdentity?], _ displays: [ExternalDisplay]) -> [ServiceMatch] {
        if services.count == 1, displays.count == 1 {
            return [ServiceMatch(service: 0, display: displays[0].id, basis: .single)]
        }
        var out: [ServiceMatch] = []
        var freeS = Array(services.indices)
        var freeD = Array(displays.indices)
        func take(_ s: Int, _ d: Int, _ basis: ServiceMatch.Basis) {
            out.append(ServiceMatch(service: s, display: displays[d].id, basis: basis))
            freeS.removeAll { $0 == s }
            freeD.removeAll { $0 == d }
        }
        for s in freeS {
            guard let a = services[s], a.serial != 0,
                  let d = freeD.first(where: { displays[$0].identity == a }) else { continue }
            take(s, d, .serial)
        }
        for s in freeS {
            guard let a = services[s] else { continue }
            let same = { (i: DisplayIdentity) in i.vendor == a.vendor && i.model == a.model }
            let ss = freeS.filter { services[$0].map(same) ?? false }
            let ds = freeD.filter { same(displays[$0].identity) }
            guard freeS.contains(s), ss.first == s, !ds.isEmpty else { continue }
            if ss.count == 1, ds.count == 1 { take(s, ds[0], .vendorModel); continue }
            for (si, di) in zip(ss, ds) { take(si, di, .order) }
        }
        let unknown = freeS.filter { services[$0] == nil }
        if !unknown.isEmpty, unknown.count == freeS.count, unknown.count == freeD.count {
            for (si, di) in zip(unknown, freeD) { take(si, di, .order) }
        }
        return out.sorted { $0.service < $1.service }
    }

    /// Pure: the DCP port a registry node belongs to, from its own / ancestors' names:
    /// "dispext0" (ioreg shows "dispext0@88000000"), "dispext0:dcpav-service-epic:0",
    /// "dcpext0" → "ext0"; "disp0", "dcp" → "0". nil if no such ancestor.
    static func portKey(names: [String]) -> String? {
        for n in names {
            let lower = n.lowercased()
            for prefix in ["dispext", "dcpext", "disp", "dcp"] where lower.hasPrefix(prefix) {
                let rest = lower.dropFirst(prefix.count)
                let digits = rest.prefix { $0.isNumber }
                let after = rest.dropFirst(digits.count).first
                guard after == nil || after == "@" || after == ":" else { continue }
                if prefix == "disp" && digits.isEmpty { continue }    // "disp@" isn't a port name
                return (prefix.hasSuffix("ext") ? "ext" : "") + (digits.isEmpty ? "0" : String(digits))
            }
        }
        return nil
    }

    /// Pure: identity from a framebuffer's `DisplayAttributes` (→ `ProductAttributes`:
    /// ManufacturerID "GSM" or number, ProductID, SerialNumber), else from its
    /// `EDID UUID` ("VVVVPPPP-…": vendor big-endian, product byte-swapped, no serial).
    static func identity(displayAttributes: [String: Any]?, edidUUID: String?) -> DisplayIdentity? {
        func num(_ v: Any?) -> UInt32? {
            if let n = v as? NSNumber { return UInt32(truncatingIfNeeded: n.int64Value) }
            if let s = v as? String { return UInt32(s) }
            return nil
        }
        if let pa = displayAttributes?["ProductAttributes"] as? [String: Any] {
            let vendor = (pa["ManufacturerID"] as? String).flatMap(DisplayIdentity.pnpVendor)
                ?? num(pa["ManufacturerID"]) ?? num(pa["LegacyManufacturerID"])
            if let vendor, let model = num(pa["ProductID"]) ?? num(pa["LegacyProductID"]) {
                return DisplayIdentity(vendor: vendor, model: model, serial: num(pa["SerialNumber"]) ?? 0)
            }
        }
        let hex = (edidUUID ?? "").replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8, let v = UInt32(hex.prefix(4), radix: 16),
              let p = UInt32(hex.dropFirst(4).prefix(4), radix: 16), v != 0 else { return nil }
        return DisplayIdentity(vendor: v, model: (p & 0xFF) << 8 | p >> 8, serial: 0)
    }

    /// Pure: identity key for the (current, max) cache; identical monitors without
    /// serials are told apart by display ID.
    static func cacheKey(_ identity: DisplayIdentity?, display: CGDirectDisplayID?, service: Int) -> String {
        let suffix = display.map { "#display\($0)" } ?? "#service\(service)"
        guard let identity else { return suffix }
        return identity.serial != 0 ? "\(identity)" : "\(identity)\(suffix)"
    }

    // MARK: - DisplayServices (private, stable since 10.12)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static func setWithDisplayServices(_ display: CGDirectDisplayID, delta: Double) -> Bool {
        guard let ds, let g = dlsym(ds, "DisplayServicesGetBrightness"),
              let s = dlsym(ds, "DisplayServicesSetBrightness") else { return false }
        if let c = dlsym(ds, "DisplayServicesCanChangeBrightness"),
           !unsafeBitCast(c, to: CanFn.self)(display) { return false }
        var current: Float = 0
        guard unsafeBitCast(g, to: GetFn.self)(display, &current) == 0 else { return false }
        let next = max(0, min(1, current + Float(delta)))
        return unsafeBitCast(s, to: SetFn.self)(display, next) == 0
    }

    // MARK: - DDC/CI

    enum DDC {
        static let queue = DispatchQueue(label: "gesturekit.ddc")
        static let brightnessVCP: UInt8 = 0x10
        static let chipAddress: UInt32 = 0x37
        static let hostAddress: UInt8 = 0x51
        static let displayAddress: UInt8 = 0x6E

        /// Last known (current, max) per display identity (`cacheKey`); DDC reads are
        /// flaky, so after a successful set we trust our own value. DDC queue only.
        private static var cache: [String: (Int, Int)] = [:]
        /// Mapping notes already logged (inferred pairs / fallbacks), so repeated
        /// gestures don't flood the log. DDC queue only.
        private static var logged: Set<String> = []

        private static func logOnce(_ msg: String) {
            if logged.insert(msg).inserted { Log.write(msg) }
        }

        /// "Set VCP" request: [0x84, 0x03, vcp, hi, lo, checksum].
        static func writePacket(vcp: UInt8, value: UInt16) -> [UInt8] {
            packet([0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
        }

        /// "Get VCP" request: [0x82, 0x01, vcp, checksum].
        static func readPacket(vcp: UInt8) -> [UInt8] {
            packet([0x01, vcp])
        }

        /// Length byte (0x80 | n) + payload + checksum over dest/src addresses and all bytes.
        private static func packet(_ payload: [UInt8]) -> [UInt8] {
            var p = [UInt8(0x80 | payload.count)] + payload
            p.append(p.reduce(displayAddress ^ hostAddress) { $0 ^ $1 })
            return p
        }

        /// Parse a "VCP feature reply": … 0x02, result(0), vcp, type, maxH, maxL, curH, curL, chk.
        static func parseReply(_ r: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
            guard let i = r.firstIndex(of: 0x02), i + 8 < r.count,
                  r[i + 1] == 0x00, r[i + 2] == vcp else { return nil }
            let mx = Int(r[i + 4]) << 8 | Int(r[i + 5])
            let cur = Int(r[i + 6]) << 8 | Int(r[i + 7])
            guard mx > 0, cur <= mx else { return nil }
            return (cur, mx)
        }

        // IOAVService (Apple Silicon; absent on Intel → DDC unavailable)
        private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
        private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

        private static func fn<T>(_ name: String, _: T.Type) -> T? {
            guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }   // RTLD_DEFAULT
            return unsafeBitCast(s, to: T.self)
        }

        /// An external `DCPAVServiceProxy` plus what we know about the monitor behind it.
        struct AVService {
            var service: CFTypeRef
            var port: String?                 // DCP port key, see `portKey`
            var identity: DisplayIdentity?    // from the framebuffer on the same port
            var link: String                  // how identity was found (probe/log)
        }

        private struct Framebuffer {
            var order: Int
            var port: String?
            var identity: DisplayIdentity?
        }

        /// External display AV services, in registry order, each paired with the
        /// framebuffer (`AppleCLCD2` / `IOMobileFramebufferShim`) of the same DCP port.
        /// Read-only: walks the IOService plane, no I²C traffic.
        static func externalServices() -> [AVService] { scan().services }

        private static func scan() -> (services: [AVService], framebuffers: [Framebuffer]) {
            guard let create = fn("IOAVServiceCreateWithService", CreateFn.self) else {
                Log.write("brightness: IOAVService unavailable (Intel Mac?), no DDC")
                return ([], [])
            }
            var iter: io_iterator_t = 0
            let root = IORegistryGetRootEntry(kIOMainPortDefault)
            defer { IOObjectRelease(root) }
            guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
                                                &iter) == KERN_SUCCESS else { return ([], []) }
            defer { IOObjectRelease(iter) }
            var fbs: [Framebuffer] = []
            var found: [(order: Int, svc: CFTypeRef, port: String?)] = []
            var order = 0
            while true {
                let entry = IOIteratorNext(iter)
                if entry == 0 { break }
                defer { IOObjectRelease(entry) }
                order += 1
                if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0 {
                    guard property(entry, "Location") as? String == "External",
                          let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                    found.append((order, svc, DisplayBrightness.portKey(names: ancestry(entry))))
                } else if IOObjectConformsTo(entry, "AppleCLCD2") != 0
                            || IOObjectConformsTo(entry, "IOMobileFramebufferShim") != 0 {
                    let id = DisplayBrightness.identity(displayAttributes: property(entry, "DisplayAttributes") as? [String: Any],
                                                        edidUUID: property(entry, "EDID UUID") as? String)
                    fbs.append(Framebuffer(order: order, port: DisplayBrightness.portKey(names: ancestry(entry)), identity: id))
                }
            }
            return (pair(found, fbs), fbs)
        }

        /// Same port first; otherwise the nearest framebuffer before the service in
        /// registry order (dispextN sits just before dcpextN), not already claimed.
        private static func pair(_ found: [(order: Int, svc: CFTypeRef, port: String?)],
                                 _ fbs: [Framebuffer]) -> [AVService] {
            var claimed = Set<Int>()
            var out = found.map { f -> AVService in
                let same = fbs.filter { f.port != nil && $0.port == f.port && $0.identity != nil }
                if same.count == 1 {
                    claimed.insert(same[0].order)
                    return AVService(service: f.svc, port: f.port, identity: same[0].identity, link: "port \(f.port!)")
                }
                return AVService(service: f.svc, port: f.port, identity: nil, link: "none")
            }
            for (i, f) in found.enumerated() where out[i].identity == nil {
                guard let fb = fbs.last(where: { $0.order < f.order && $0.identity != nil && !claimed.contains($0.order) })
                else { continue }
                claimed.insert(fb.order)
                out[i].identity = fb.identity
                out[i].link = "registry order (推断)"
            }
            return out
        }

        private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        /// Names of the entry and its IOService-plane ancestors, nearest first.
        private static func ancestry(_ entry: io_registry_entry_t) -> [String] {
            var names: [String] = []
            var cur = entry
            IOObjectRetain(cur)
            for _ in 0..<16 {
                var buf = [CChar](repeating: 0, count: 128)        // io_name_t
                if IORegistryEntryGetName(cur, &buf) == KERN_SUCCESS { names.append(String(cString: buf)) }
                var parent: io_registry_entry_t = 0
                let r = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent)
                IOObjectRelease(cur)
                guard r == KERN_SUCCESS, parent != 0 else { return names }
                cur = parent
            }
            IOObjectRelease(cur)
            return names
        }

        /// Pure: which service indices to talk to. Every target must be mapped;
        /// otherwise fall back to all external services (old behaviour).
        static func plan(targets: [CGDirectDisplayID], matches: [ServiceMatch],
                         serviceCount: Int) -> (services: [Int], fallback: Bool) {
            var picked: [Int] = []
            for t in targets {
                guard let m = matches.first(where: { $0.display == t }) else {
                    return (Array(0..<serviceCount), true)
                }
                if !picked.contains(m.service) { picked.append(m.service) }
            }
            return (picked.sorted(), false)
        }

        /// DDC queue only.
        static func adjust(targets: [CGDirectDisplayID], externals: [ExternalDisplay], delta: Double) {
            let services = externalServices()
            if services.isEmpty { Log.write("brightness: no external DDC display found"); return }
            let matches = DisplayBrightness.matchServices(services.map(\.identity), externals)
            let p = plan(targets: targets, matches: matches, serviceCount: services.count)
            if p.fallback {
                logOnce("brightness: DDC mapping failed for displays \(targets) "
                        + "(services \(services.map { $0.identity?.description ?? "?" }), "
                        + "displays \(externals.map { "\($0.id)=\($0.identity)" })); adjusting all external DDC displays")
            }
            for m in matches where m.inferred && p.services.contains(m.service) {
                logOnce("brightness: DDC service \(m.service) → display \(m.display) 推断 (\(m.basis.rawValue))")
            }
            for i in p.services {
                let svc = services[i]
                let display = matches.first { $0.service == i }?.display
                let key = DisplayBrightness.cacheKey(svc.identity, display: display, service: i)
                guard let (cur, mx) = read(svc.service) ?? cache[key] else {
                    Log.write("brightness: DDC read failed on external display \(key)")
                    continue
                }
                let next = DisplayBrightness.step(current: cur, max: mx, delta: delta)
                if write(svc.service, value: next) {
                    cache[key] = (next, mx)
                } else {
                    Log.write("brightness: DDC write failed on external display \(key)")
                }
            }
        }

        /// Read-only description for `--ddc-probe` (no I²C traffic).
        static func probeReport() -> [String] {
            let externals = DisplayBrightness.activeExternalDisplays()
            let (services, fbs) = scan()
            var lines = ["external CG displays: \(externals.count)"]
            lines += externals.map { "  display \($0.id): \($0.identity)" }
            lines.append("framebuffers: \(fbs.count)")
            lines += fbs.map { "  port \($0.port ?? "?"): \($0.identity?.description ?? "no DisplayAttributes")" }
            lines.append("external DDC services: \(services.count)")
            for (i, s) in services.enumerated() {
                lines.append("  service \(i): port \(s.port ?? "?"), identity \(s.identity?.description ?? "?") via \(s.link)")
            }
            let matches = DisplayBrightness.matchServices(services.map(\.identity), externals)
            lines.append("mapping:")
            for i in services.indices {
                if let m = matches.first(where: { $0.service == i }) {
                    lines.append("  service \(i) → display \(m.display) [\(m.basis.rawValue)\(m.inferred ? ", 推断" : "")]")
                } else {
                    lines.append("  service \(i) → unmapped")
                }
            }
            if services.isEmpty { lines.append("  (none)") }
            let unmapped = externals.filter { e in !matches.contains { $0.display == e.id } }
            if !services.isEmpty, !unmapped.isEmpty {
                lines.append("  unmapped displays \(unmapped.map(\.id)) → brightness falls back to all external DDC displays")
            }
            return lines
        }

        /// `--ddc-test`: query (never set) brightness on every external service and
        /// report each step — return codes and raw reply bytes — with two answer delays.
        static func testReport() -> [String] {
            guard let w = fn("IOAVServiceWriteI2C", I2CFn.self), let r = fn("IOAVServiceReadI2C", I2CFn.self)
            else { return ["IOAVService I2C functions unavailable"] }
            var lines: [String] = []
            for (i, s) in externalServices().enumerated() {
                lines.append("service \(i) (\(s.identity?.description ?? "?")):")
                for (delay, twice) in [(UInt32(40_000), false), (100_000, false), (50_000, true), (200_000, true)] {
                    var req = readPacket(vcp: brightnessVCP)
                    var wr = w(s.service, chipAddress, UInt32(hostAddress), &req, UInt32(req.count))
                    if twice { usleep(10_000); wr = w(s.service, chipAddress, UInt32(hostAddress), &req, UInt32(req.count)) }
                    usleep(delay)
                    var reply = [UInt8](repeating: 0, count: 12)
                    let rr = r(s.service, chipAddress, 0, &reply, UInt32(reply.count))
                    let hex = reply.map { String(format: "%02X", $0) }.joined(separator: " ")
                    let parsed = parseReply(reply, vcp: brightnessVCP).map { "cur=\($0.current) max=\($0.max)" } ?? "parse failed"
                    lines.append((twice ? "  ×2" : "  ×1") + String(format: " delay %3dms  write=0x%08X  read=0x%08X  reply=[%@]  → %@",
                                        delay / 1000, wr, rr, hex, parsed))
                    usleep(50_000)
                }
            }
            if lines.isEmpty { lines.append("no external DDC services") }
            return lines
        }

        private static func read(_ svc: CFTypeRef) -> (Int, Int)? {
            guard let w = fn("IOAVServiceWriteI2C", I2CFn.self), let r = fn("IOAVServiceReadI2C", I2CFn.self)
            else { return nil }
            for _ in 0..<3 {
                var req = readPacket(vcp: brightnessVCP)
                // Send the request twice: several monitors (Xiaomi 27A1, ViewSonic VX2478 on the
                // MacBook Pro ports) answer a single request with a null message (6E 80 BE).
                guard w(svc, chipAddress, UInt32(hostAddress), &req, UInt32(req.count)) == kIOReturnSuccess
                else { continue }
                usleep(10_000)
                guard w(svc, chipAddress, UInt32(hostAddress), &req, UInt32(req.count)) == kIOReturnSuccess
                else { continue }
                usleep(50_000)                       // display needs time to answer
                var reply = [UInt8](repeating: 0, count: 12)
                guard r(svc, chipAddress, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
                if let v = parseReply(reply, vcp: brightnessVCP) { return (v.current, v.max) }
                usleep(20_000)
            }
            return nil
        }

        private static func write(_ svc: CFTypeRef, value: Int) -> Bool {
            guard let w = fn("IOAVServiceWriteI2C", I2CFn.self) else { return false }
            var pkt = writePacket(vcp: brightnessVCP, value: UInt16(value))
            // Some monitors drop the first message; send twice like most DDC tools.
            var ok = false
            for _ in 0..<2 {
                ok = w(svc, chipAddress, UInt32(hostAddress), &pkt, UInt32(pkt.count)) == kIOReturnSuccess || ok
                usleep(10_000)
            }
            return ok
        }
    }
}
