import Cocoa
import Carbon
import ImageIO

// 截图：选框状态机、坐标换算、窗口挑选、工具条位置、编码、动作接线（不弹真实界面、不截屏）。
extension SelfTest {
    static func captureChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        typealias S = CaptureSelection
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let front = CGRect(x: 100, y: 100, width: 300, height: 200)
        let back = CGRect(x: 50, y: 50, width: 600, height: 500)

        // MARK: drag / click
        do {
            var s = S(bounds: screen, windows: [front, back])
            _ = s.mouseDown(CGPoint(x: 500, y: 400), clickCount: 1)
            s.mouseDragged(CGPoint(x: 200, y: 150))
            s.mouseUp(CGPoint(x: 200, y: 150))
            check("capture: dragging up-left gives a normal rect",
                  s.rect == CGRect(x: 200, y: 150, width: 300, height: 250) && s.phase == .selected, "\(String(describing: s.rect))")

            var c = S(bounds: screen, windows: [front, back])
            c.hover(CGPoint(x: 150, y: 150))
            check("capture: hover highlights the frontmost window under the cursor", c.hovered == front)
            _ = c.mouseDown(CGPoint(x: 150, y: 150), clickCount: 1)
            c.mouseUp(CGPoint(x: 152, y: 151))
            check("capture: a click (< 4pt) selects that window", c.rect == front && c.phase == .selected)

            var d = S(bounds: screen, windows: [front])
            _ = d.mouseDown(CGPoint(x: 900, y: 700), clickCount: 1)
            d.mouseUp(CGPoint(x: 900, y: 700))
            check("capture: a click on no window selects the whole screen", d.rect == screen)

            let off = S(bounds: screen, windows: [CGRect(x: 900, y: -50, width: 300, height: 200)])
            check("capture: windows are clipped to the screen",
                  off.windows == [CGRect(x: 900, y: 0, width: 100, height: 150)])

            var e = S(bounds: screen, windows: [])
            _ = e.mouseDown(CGPoint(x: 990, y: 790), clickCount: 1)
            e.mouseDragged(CGPoint(x: 1300, y: 1200))
            e.mouseUp(CGPoint(x: 1300, y: 1200))
            check("capture: dragging off-screen stops at the edge",
                  e.rect == CGRect(x: 990, y: 790, width: 10, height: 10), "\(String(describing: e.rect))")
        }

        // MARK: adjust
        do {
            var s = S(bounds: screen, windows: [])
            _ = s.mouseDown(CGPoint(x: 100, y: 100), clickCount: 1)
            s.mouseDragged(CGPoint(x: 300, y: 200)); s.mouseUp(CGPoint(x: 300, y: 200))
            check("capture: corner handle is hit", s.handle(at: CGPoint(x: 303, y: 198)) == .bottomRight)
            check("capture: inside is the move handle", s.handle(at: CGPoint(x: 200, y: 150)) == .inside)
            check("capture: far outside is no handle", s.handle(at: CGPoint(x: 600, y: 600)) == nil)

            _ = s.mouseDown(CGPoint(x: 300, y: 200), clickCount: 1)
            s.mouseDragged(CGPoint(x: 350, y: 260)); s.mouseUp(CGPoint(x: 350, y: 260))
            check("capture: dragging the bottom-right handle resizes",
                  s.rect == CGRect(x: 100, y: 100, width: 250, height: 160) && s.phase == .selected)

            _ = s.mouseDown(CGPoint(x: 100, y: 100), clickCount: 1)
            s.mouseDragged(CGPoint(x: 400, y: 300)); s.mouseUp(CGPoint(x: 400, y: 300))
            check("capture: dragging a corner past the opposite one flips, not inverts",
                  s.rect == CGRect(x: 350, y: 260, width: 50, height: 40), "\(String(describing: s.rect))")

            _ = s.mouseDown(CGPoint(x: 370, y: 280), clickCount: 1)
            s.mouseDragged(CGPoint(x: 2000, y: 2000)); s.mouseUp(CGPoint(x: 2000, y: 2000))
            check("capture: moving keeps the size and stays on screen",
                  s.rect == CGRect(x: 950, y: 760, width: 50, height: 40), "\(String(describing: s.rect))")

            s.nudge(dx: -1, dy: 0)
            s.nudge(dx: -10, dy: -10)
            check("capture: arrow keys nudge", s.rect == CGRect(x: 939, y: 750, width: 50, height: 40))
            s.nudge(dx: 5, dy: 5, resize: true)
            check("capture: ⌥ + arrow keys resize", s.rect == CGRect(x: 939, y: 750, width: 55, height: 45))

            check("capture: double-click inside confirms",
                  s.mouseDown(CGPoint(x: 960, y: 770), clickCount: 2) == .confirm)
            var t = s
            _ = t.mouseDown(CGPoint(x: 10, y: 10), clickCount: 1)
            check("capture: pressing outside starts a new selection", t.rect == nil)

            check("capture: first Esc clears the selection", s.escape() == false && s.rect == nil && s.phase == .idle)
            check("capture: second Esc exits", s.escape() == true)
        }

        // MARK: geometry helpers
        do {
            let px = S.pixelRect(CGRect(x: 10.3, y: 20.6, width: 100.2, height: 50.1), scale: 2,
                                 imageSize: CGSize(width: 2000, height: 1600))
            check("capture: Retina pixel rect is integral", px == CGRect(x: 20, y: 41, width: 201, height: 101), "\(px)")
            let edge = S.pixelRect(CGRect(x: 990, y: 790, width: 20, height: 20), scale: 2,
                                   imageSize: CGSize(width: 2000, height: 1600))
            check("capture: pixel rect stays inside the image", edge == CGRect(x: 1980, y: 1580, width: 20, height: 20))

            let tb = CGSize(width: 102, height: 30)
            let below = S.toolbarFrame(for: CGRect(x: 100, y: 100, width: 300, height: 200), size: tb, in: screen)
            check("capture: toolbar sits below, right-aligned", below == CGRect(x: 298, y: 306, width: 102, height: 30))
            let above = S.toolbarFrame(for: CGRect(x: 100, y: 500, width: 300, height: 290), size: tb, in: screen)
            check("capture: no room below → above", above.maxY == 494)
            let inside = S.toolbarFrame(for: screen, size: tb, in: screen)
            check("capture: full screen → inside the bottom-right corner",
                  inside == CGRect(x: 898, y: 764, width: 102, height: 30))
            let tiny = S.toolbarFrame(for: CGRect(x: 0, y: 100, width: 20, height: 20), size: tb, in: screen)
            check("capture: toolbar never leaves the screen", tiny.minX >= 0 && screen.contains(tiny))
            let label = S.sizeLabelOrigin(for: CGRect(x: 5, y: 2, width: 50, height: 50),
                                          size: CGSize(width: 60, height: 16), in: screen)
            check("capture: size label moves inside when there is no room above", label == CGPoint(x: 5, y: 6))
        }

        // MARK: window list
        do {
            func w(_ layer: Int, _ pid: Int32, _ r: CGRect, alpha: Double = 1) -> [String: Any] {
                [kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid, kCGWindowAlpha as String: alpha,
                 kCGWindowBounds as String: r.dictionaryRepresentation as NSDictionary]
            }
            let picked = Capture.pickWindows([
                w(0, 10, front), w(25, 11, back), w(0, 99, back), w(0, 12, CGRect(x: 0, y: 0, width: 10, height: 300)),
                w(0, 13, back, alpha: 0), w(0, 14, back),
            ], ownPID: 99)
            check("capture: picks normal, visible, not-tiny windows of other apps, in order",
                  picked == [front, back], "\(picked)")
        }

        // MARK: output
        do {
            let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(NSColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            let img = ctx.makeImage()!
            let png = Capture.png(img, scale: 2)
            let props = png.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            check("capture: PNG keeps pixels and marks Retina as 144 dpi",
                  props?[kCGImagePropertyPixelWidth] as? Int == 40
                    && (props?[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 144) < 0.5 } == true,
                  "\(String(describing: props))")
            let f = Capture.Frozen(displayID: 1, image: img, cgBounds: CGRect(x: 0, y: 0, width: 20, height: 10),
                                   cocoaFrame: .zero, scale: 2)
            let cropped = Capture.crop(f, rect: CGRect(x: 5, y: 2, width: 10, height: 5))
            check("capture: crop takes the selection at full resolution",
                  cropped?.width == 20 && cropped?.height == 10)
            check("capture: an empty selection crops nothing", Capture.crop(f, rect: CGRect(x: 5, y: 2, width: 0, height: 5)) == nil)

            var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 10
            comps.hour = 18; comps.minute = 30; comps.second = 5
            let date = Calendar.current.date(from: comps)!
            let name = Capture.fileName(date)
            check("capture: desktop file name", name.hasSuffix("2026-11-10 18.30.05.png") && !name.contains("/"), name)
        }

        // MARK: wiring
        do {
            check("capture: hotkey is ⌃⌘A", Capture.hotkeyKeyCode == 0
                  && Capture.hotkeyModifiers == UInt32(controlKey | cmdKey))
            check("capture: taken hotkey is reported as taken",
                  Hotkey.status(for: OSStatus(eventHotKeyExistsErr)) == .taken && Hotkey.status(for: noErr) == .ok)

            let savedDry = Actions.dryRun, savedObserver = Actions.observer, savedPresenter = Actions.presenter
            Actions.dryRun = false; Actions.observer = nil; Actions.presenter = nil
            let fx = RecordingActionEffects()
            let actions = Actions()
            actions.effects = fx
            actions.perform(ActionSpec(type: "system", keyCode: nil, modifiers: nil, label: nil, op: "capture", delta: nil))
            Actions.dryRun = savedDry; Actions.observer = savedObserver; Actions.presenter = savedPresenter
            let posted: Bool = { if case .notification(let n)? = fx.calls.first { return n == Capture.startNotification }; return false }()
            check("capture: the 截图 action starts a capture", posted && fx.calls.count == 1)
            check("capture: action is listed under 截图",
                  ActionCatalog.systemGroups.first { $0.0 == "截图" }?.1.first == "capture")

            var cfg = Config.defaultConfig
            check("capture: hotkey on by default", cfg.captureHotkey ?? true)
            cfg.captureHotkey = false
            let back = (try? JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg)))?.captureHotkey
            check("capture: turning the hotkey off survives a save", back == false)
        }
        return out
    }
}
