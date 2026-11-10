import Cocoa
import Carbon
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 截图的底层：权限、定格屏幕、窗口列表、裁剪、编码、剪贴板、存桌面。
/// 界面在 CaptureOverlay.swift，选框逻辑在 CaptureSelection.swift。
enum Capture {

    /// 「截图」动作（system/capture）发出，AppDelegate 收到后开始截图
    static let startNotification = Notification.Name("GestureKit.startCapture")

    /// 截图的默认快捷键 ⌃⌘A（kVK_ANSI_A = 0）
    static let hotkeyKeyCode: UInt32 = 0
    static let hotkeyModifiers: UInt32 = UInt32(controlKey | cmdKey)

    /// 一块屏幕的定格画面
    struct Frozen {
        let displayID: CGDirectDisplayID
        let image: CGImage
        /// 全局坐标（左上原点，与 CGEvent.location 相同），单位点
        let cgBounds: CGRect
        /// Cocoa 坐标（左下原点），遮罩窗口用
        let cocoaFrame: NSRect
        let scale: CGFloat
    }

    // MARK: - Permission

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 没有「屏幕录制」权限：请求一次（系统会把 GestureKit 加进列表），并说明怎么开。
    static func explainPermission() {
        let alreadyAsked = UserDefaults.standard.bool(forKey: "askedScreenCapture")
        UserDefaults.standard.set(true, forKey: "askedScreenCapture")
        if !alreadyAsked { _ = CGRequestScreenCaptureAccess() }
        Log.write("capture: no screen recording permission")
        let a = NSAlert()
        a.messageText = L("截图需要「屏幕录制」权限")
        a.informativeText = L("请在 系统设置 → 隐私与安全性 → 屏幕与系统录音 里打开 GestureKit。打开后如果仍无法截图，请退出并重新打开 GestureKit。")
        a.addButton(withTitle: L("打开系统设置"))
        a.addButton(withTitle: L("取消"))
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    // MARK: - Windows

    /// 屏幕上的普通窗口（从前到后），全局坐标；不含 GestureKit 自己的窗口。
    static func windowRects() -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return pickWindows(info, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// 从 CGWindowList 的条目里挑出可选的窗口：普通层级、可见、不太小、不是自己。
    static func pickWindows(_ info: [[String: Any]], ownPID: pid_t) -> [CGRect] {
        info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  r.width >= 20, r.height >= 20 else { return nil }
            return r
        }
    }

    // MARK: - Freeze

    /// 定格所有屏幕（ScreenCaptureKit，Retina 原分辨率，不含光标和 GestureKit 自己的窗口）。
    static func freezeAll() async -> [Frozen] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.write("capture: shareable content failed: \(error.localizedDescription)")
            return []
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let screens: [(CGDirectDisplayID, NSRect, CGFloat)] = await MainActor.run {
            NSScreen.screens.compactMap { s in
                guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                else { return nil }
                return (id, s.frame, s.backingScaleFactor)
            }
        }
        return await withTaskGroup(of: Frozen?.self) { group in
            for d in content.displays {
                guard let (_, frame, scale) = screens.first(where: { $0.0 == d.displayID }) else { continue }
                group.addTask {
                    let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = Int(CGFloat(d.width) * scale)
                    cfg.height = Int(CGFloat(d.height) * scale)
                    cfg.showsCursor = false
                    cfg.captureResolution = .best
                    do {
                        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                        return Frozen(displayID: d.displayID, image: img, cgBounds: CGDisplayBounds(d.displayID),
                                      cocoaFrame: frame, scale: scale)
                    } catch {
                        Log.write("capture: display \(d.displayID) failed: \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            var out: [Frozen] = []
            for await f in group { if let f { out.append(f) } }
            return out
        }
    }

    // MARK: - Output

    /// 选框（本屏点坐标）→ 裁剪后的图
    static func crop(_ f: Frozen, rect: CGRect) -> CGImage? {
        let px = CaptureSelection.pixelRect(rect, scale: f.scale,
                                            imageSize: CGSize(width: f.image.width, height: f.image.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        return f.image.cropping(to: px)
    }

    /// PNG，带 DPI（Retina = 144），粘贴到别处时按原本的点尺寸显示。
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi,
                                                 kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// 写入剪贴板：PNG + TIFF（有的 App 只认 TIFF）
    static func copyToPasteboard(_ image: CGImage, png: Data, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// 桌面上的文件名：「截图 2026-11-10 18.30.12.png」
    static func fileName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return L("截图 %@", f.string(from: date)) + ".png"
    }

    /// 存到桌面，同名时加 (2)、(3)…；返回写入的路径
    static func saveToDesktop(_ png: Data, date: Date = Date()) -> URL? {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let name = fileName(date)
        var url = desktop.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent((name as NSString).deletingPathExtension + " (\(n)).png")
            n += 1
        }
        do { try png.write(to: url); return url } catch {
            Log.write("capture: save failed: \(error.localizedDescription)")
            return nil
        }
    }
}
