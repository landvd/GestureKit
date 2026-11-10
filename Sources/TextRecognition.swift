import Cocoa
import Vision

/// 识别图里的文字（Vision，本机离线，不联网）。在后台队列跑，结果回主线程。
enum TextRecognition {

    struct Line: Equatable {
        let text: String
        /// Vision 的归一化坐标：左下原点，0…1
        let box: CGRect
    }

    /// 识别并复制到剪贴板，HUD 提示结果
    static func copyText(in image: CGImage) {
        HUD.shared.show(L("正在识别文字…"), duration: 2)
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            let text = recognize(image)
            DispatchQueue.main.async {
                Log.write(String(format: "ocr: %d chars in %.0f ms", text.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                guard !text.isEmpty else { HUD.shared.show(L("没有识别到文字"), duration: 1); return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                HUD.shared.show(L("已复制 %d 个字", text.count), duration: 1)
            }
        }
    }

    /// 每个新编译的程序第一次识别要先编译模型（实测约 27 秒，之后同一程序每次约 0.2 秒，重启也是）。
    /// 启动 10 秒后在后台用最低优先级识别一张小图，让用户第一次按 T 时不用等。
    static func warmUp() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let text = recognize(sample())
            Log.write(String(format: "ocr: warm-up %.0f ms (%@)", (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                             text.isEmpty ? "no text" : "ok"))
        }
    }

    /// 一张写着字的小图（预热和 --ocr-test 用）
    static func sample(width: Int = 900, height: Int = 220) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
        ("GestureKit 2026" as NSString).draw(at: NSPoint(x: 30, y: 120), withAttributes: attrs)
        ("截图识别测试" as NSString).draw(at: NSPoint(x: 30, y: 30), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// `--ocr-test`：真实识别一张中英文图（新编译的程序第一次约 27 秒，所以不放进 --selftest）
    static func runTest() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)")
            if !ok { fails += 1 }
        }
        for round in 1...2 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let text = recognize(sample())
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            check("ocr #\(round): English", text.contains("GestureKit") && text.contains("2026"), text.replacingOccurrences(of: "\n", with: " | "))
            check("ocr #\(round): Chinese", text.contains("截图识别"), "")
            check("ocr #\(round): top line first", text.hasPrefix("GestureKit"), "")
            print(String(format: "      ocr #%d: %.0f ms%@", round, ms, round == 1 ? "（新编译的程序首次约 27 秒，属正常）" : ""))
            if round == 2 { check("ocr: warm recognition < 1 s", ms < 1000, String(format: "%.0f ms", ms)) }
        }
        print(fails == 0 ? "ALL OCR TESTS PASSED" : "\(fails) OCR TEST(S) FAILED")
        return fails == 0 ? 0 : 1
    }

    /// 同步识别（调用方负责放在后台）
    static func recognize(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image).perform([req]) } catch {
            Log.write("ocr: failed: \(error.localizedDescription)")
            return ""
        }
        let lines = (req.results ?? []).compactMap { o in
            o.topCandidates(1).first.map { Line(text: $0.string, box: o.boundingBox) }
        }
        return join(lines)
    }

    /// 按阅读顺序拼起来：从上到下；同一行（纵向大半重叠）的从左到右，用空格隔开。
    static func join(_ lines: [Line]) -> String {
        let sorted = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Line]] = []
        for l in sorted {
            if let last = rows.last?.first, overlap(last.box, l.box) > 0.5 {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// 纵向重叠占较矮那个的比例
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return max(0, h) / max(min(a.height, b.height), 0.0001)
    }
}
