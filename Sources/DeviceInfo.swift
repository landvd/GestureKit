import Cocoa

/// Connected pointing device identity for the "按键识别" page, built on
/// `HIDMouse` (enumeration only — never opens the device, so no Input
/// Monitoring prompt).
enum DeviceInfo {
    struct Mouse: Equatable {
        var product: String
        var manufacturer: String
        var productID: String
        var transport: String
        var vendorID: String = "—"
        var buttons: String = "—"
    }

    static func mouse(from d: HIDMouseInfo) -> Mouse {
        Mouse(product: d.product, manufacturer: d.manufacturer,
              productID: d.productIDText, transport: d.transportText,
              vendorID: d.vendorIDText, buttons: d.buttonCountText)
    }

    /// First connected mouse (external mice before trackpads); nil if none.
    static func currentMouse() -> Mouse? {
        HIDMouse.enumerate().first.map(mouse(from:))
    }

    static func allMice() -> [HIDMouseInfo] { HIDMouse.enumerate() }
}
