// Draws the GestureKit app icon and writes Resources/AppIcon.icns.
// Original artwork, code only (no third-party assets). Run: swift scripts/make-icon.swift
//
// Design: macOS rounded-square body with a soft drop shadow, indigo → violet → pink
// gradient, a white gesture trail that fades in from its tail, ending at a pointer.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Cubic Bézier sampled into points.
func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, steps: Int) -> [CGPoint] {
    (0...steps).map { i in
        let t = CGFloat(i) / CGFloat(steps), u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p1.x
        let y = u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p1.y
        return CGPoint(x: x, y: y)
    }
}

func drawIcon(_ ctx: CGContext) {
    let s = canvas
    // Big Sur icon grid: 824 pt body centred in 1024, continuous corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 186
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.32))
    ctx.addPath(shape); ctx.setFillColor(color(0x5B5BD6)); ctx.fillPath()
    ctx.restoreGState()

    // Gradient body
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x4F7CFF), color(0x7C5CFF), color(0xC04CF0), color(0xFF5FA2)] as CFArray,
                          locations: [0, 0.38, 0.72, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft light from the top
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.36, y: s * 0.86), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.36, y: s * 0.86), endRadius: s * 0.62, options: [])
    // Faint inner rim
    ctx.addPath(shape); ctx.setStrokeColor(color(0xFFFFFF, 0.14)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.restoreGState()

    // Gesture trail: one tapered outline (thin tail → full width at the head), filled with
    // a white gradient that fades in from the tail. Drawn as a single shape so there is
    // no overlap banding.
    let tip = CGPoint(x: 612, y: 676)                         // pointer tip
    let end = CGPoint(x: tip.x + 38, y: tip.y - 92)           // trail ends under the pointer body
    let pts = bezier(CGPoint(x: 232, y: 300), CGPoint(x: 300, y: 690),
                     CGPoint(x: 500, y: 150), CGPoint(x: 566, y: 520), steps: 220)
        + bezier(CGPoint(x: 566, y: 520), CGPoint(x: 584, y: 610),
                 CGPoint(x: 606, y: 640), end, steps: 60).dropFirst()
    let n = pts.count
    func width(_ t: CGFloat) -> CGFloat { 6 + 50 * pow(t, 0.7) }
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0..<n {
        let a = pts[max(0, i - 1)], b = pts[min(n - 1, i + 1)]
        let dx = b.x - a.x, dy = b.y - a.y, len = max(0.001, hypot(dx, dy))
        let nx = -dy / len, ny = dx / len, w = width(CGFloat(i) / CGFloat(n - 1)) / 2
        left.append(CGPoint(x: pts[i].x + nx * w, y: pts[i].y + ny * w))
        right.append(CGPoint(x: pts[i].x - nx * w, y: pts[i].y - ny * w))
    }
    let ribbon = CGMutablePath()
    ribbon.addLines(between: left + right.reversed())
    ribbon.closeSubpath()
    let headR = width(1) / 2
    ribbon.addEllipse(in: CGRect(x: end.x - headR, y: end.y - headR, width: headR * 2, height: headR * 2))
    ribbon.addEllipse(in: CGRect(x: pts[0].x - 3, y: pts[0].y - 3, width: 6, height: 6))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x2A1066, 0.38))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(ribbon); ctx.clip()
    let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFFFFF, 0.05), color(0xFFFFFF, 0.75), color(0xFFFFFF, 1)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(fade, start: pts[0], end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Motion dots behind the tail
    for (i, d) in [(CGPoint(x: 214, y: 250), 13.0), (CGPoint(x: 202, y: 212), 9.0), (CGPoint(x: 194, y: 182), 6.0)].enumerated() {
        ctx.setFillColor(color(0xFFFFFF, 0.42 - 0.12 * CGFloat(i)))
        ctx.fillEllipse(in: CGRect(x: d.0.x - d.1, y: d.0.y - d.1, width: d.1 * 2, height: d.1 * 2))
    }

    // Pointer whose tip sits on the end of the trail (classic system-arrow proportions)
    let unit: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.1, y: 13.2),
                           CGPoint(x: 6.9, y: 19.6), CGPoint(x: 9.7, y: 18.4), CGPoint(x: 6.9, y: 12.1),
                           CGPoint(x: 12.3, y: 12.1)]
    let k: CGFloat = 14.5
    let arrow = CGMutablePath()
    arrow.addLines(between: unit.map { CGPoint(x: tip.x + $0.x * k, y: tip.y - $0.y * k) })
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x1B0B4A, 0.45))
    ctx.addPath(arrow); ctx.setFillColor(color(0x1F1A3D)); ctx.fillPath()
    ctx.restoreGState()
    ctx.setLineJoin(.round)
    ctx.addPath(arrow); ctx.setStrokeColor(color(0x1F1A3D)); ctx.setLineWidth(12); ctx.strokePath()
    ctx.addPath(arrow); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
}

func render(size px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / canvas, y: CGFloat(px) / canvas)
    drawIcon(ctx)
    g.flushGraphics()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build-icon/AppIcon.iconset")
let fm = FileManager.default
try? fm.removeItem(at: iconset.deletingLastPathComponent())
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: base * scale).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("build-icon/preview-1024.png"))
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
