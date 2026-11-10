import Cocoa

// 钉图（位置、缩放）与识别文字的阅读顺序。不弹窗；真实 Vision 识别见 --ocr-test。
extension SelfTest {
    static func pinOCRChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }

        // MARK: pin geometry
        do {
            let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)
            let small = PinnedImages.centered(NSSize(width: 400, height: 300), in: screen)
            check("pin: small shots open at 100% in the middle", small == NSRect(x: 760, y: 375, width: 400, height: 300))
            let big = PinnedImages.centered(NSSize(width: 3000, height: 1000), in: screen)
            check("pin: big shots shrink to 60% of the screen", big.width == 1152 && big.height == 384, "\(big)")

            let f = NSRect(x: 100, y: 100, width: 200, height: 100)
            let z = PinnedImages.zoomed(f, base: NSSize(width: 200, height: 100), to: 2, anchor: NSPoint(x: 150, y: 125))
            check("pin: zoom keeps the point under the cursor", z == NSRect(x: 50, y: 75, width: 400, height: 200), "\(z)")
            let tiny = PinnedImages.zoomed(f, base: NSSize(width: 200, height: 100), to: 0.01, anchor: NSPoint(x: 100, y: 100))
            let huge = PinnedImages.zoomed(f, base: NSSize(width: 200, height: 100), to: 99, anchor: NSPoint(x: 100, y: 100))
            check("pin: zoom stays within 25% … 400%", tiny.width == 50 && huge.width == 800)

            let frozen = Capture.Frozen(displayID: 1, image: SelfTest.solidImage(4, 4),
                                        cgBounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                        cocoaFrame: NSRect(x: 1920, y: 0, width: 1920, height: 1080), scale: 1)
            check("pin: a pinned shot opens exactly where it was selected",
                  CaptureController.cocoaRect(CGRect(x: 100, y: 50, width: 300, height: 200), in: frozen)
                    == NSRect(x: 2020, y: 830, width: 300, height: 200))
            let tb = CaptureSelection.toolbarFrame(for: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                   size: CGSize(width: 170, height: 30),
                                                   in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            check("pin: the 5-button toolbar stays on screen", tb.minX >= 0)
        }

        // MARK: reading order
        do {
            typealias Line = TextRecognition.Line
            let lines = [
                Line(text: "world", box: CGRect(x: 0.5, y: 0.80, width: 0.3, height: 0.1)),
                Line(text: "third", box: CGRect(x: 0.1, y: 0.20, width: 0.3, height: 0.1)),
                Line(text: "hello", box: CGRect(x: 0.1, y: 0.82, width: 0.3, height: 0.1)),
                Line(text: "second", box: CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.1)),
            ]
            check("ocr: top to bottom, same row left to right",
                  TextRecognition.join(lines) == "hello world\nsecond\nthird", TextRecognition.join(lines))
            check("ocr: nothing → empty", TextRecognition.join([]).isEmpty)
        }

        // 真实识别（Vision）见 `--ocr-test`：新编译的程序第一次要约 27 秒编译模型，不放进每次构建
        do {
            let img = TextRecognition.sample()
            check("ocr: test image is drawn", img.width == 900 && img.height == 220)
        }
        return out
    }

    static func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.gray.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}
