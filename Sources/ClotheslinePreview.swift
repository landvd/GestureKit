import SwiftUI

/// 设置页「衣架样式」：每种样式用真实的衣架视图（缩小）挂三张示例图，点一下选中。
/// 预览用临时文件夹里的示例图，不碰真实衣架；卡片不响应悬停 / 点击。
enum ClotheslinePreview {

    /// 预览衣架的逻辑尺寸（缩小显示）
    static let canvas = NSSize(width: 400, height: ClotheslineLayout.panelHeight)

    /// 三张示例图，所有预览共用（临时文件夹，第一次用到时生成）
    static let store: ClotheslineStore = {
        let s = ClotheslineStore(dir: FileManager.default.temporaryDirectory
            .appendingPathComponent("gk-clothesline-preview"))
        s.removeAll()
        let shapes: [(Int, Int, NSColor)] = [(800, 560, .systemBlue), (500, 640, .systemOrange), (900, 520, .systemGreen)]
        for (i, (w, h, color)) in shapes.enumerated() {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.fill(CGRect(x: w / 10, y: h / 2, width: w * 6 / 10, height: h / 10))
            ctx.fill(CGRect(x: w / 10, y: h / 3, width: w * 4 / 10, height: h / 10))
            guard let img = ctx.makeImage(), let png = Capture.png(img, scale: 2) else { continue }
            s.add(png: png, pixelWidth: w, pixelHeight: h, scale: 2,
                  date: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60))
        }
        return s
    }()
}

/// 缩小显示一条真实的衣架（bounds 比 frame 大 → 整体按比例缩小）
final class ClotheslinePreviewHost: NSView {

    private let controller = ClotheslineController()
    private let line: ClotheslineView

    init(style: ClotheslineStyle) {
        controller.isPreview = true
        controller.store = ClotheslinePreview.store
        controller.style = style
        line = ClotheslineView(controller: controller)
        super.init(frame: NSRect(origin: .zero, size: ClotheslinePreview.canvas))
        wantsLayer = true
        line.frame = NSRect(origin: .zero, size: ClotheslinePreview.canvas)
        addSubview(line)
        line.reload(dropping: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(ClotheslinePreview.canvas)
    }

    /// 只是展示：点击交给 SwiftUI（选中样式）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setStyle(_ style: ClotheslineStyle) { controller.style = style }
}

struct ClotheslineStylePreview: NSViewRepresentable {
    let style: ClotheslineStyle
    func makeNSView(context: Context) -> ClotheslinePreviewHost { ClotheslinePreviewHost(style: style) }
    func updateNSView(_ v: ClotheslinePreviewHost, context: Context) { v.setStyle(style) }
}

/// 五种样式的网格，选中的描边高亮
struct ClotheslineStylePicker: View {
    @ObservedObject var model: PrefModel

    var body: some View {
        let current = ClotheslineStyle(config: model.config.clotheslineStyle)
        // 三列不能太宽：内容区放不下时会把整个设置窗口的布局（含侧栏）往左挤
        let columns = Array(repeating: GridItem(.fixed(152), spacing: 8), count: 3)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(ClotheslineStyle.allCases, id: \.rawValue) { st in
                let selected = st == current
                VStack(spacing: 4) {
                    ClotheslineStylePreview(style: st)
                        .frame(width: 148, height: 148 * ClotheslinePreview.canvas.height / ClotheslinePreview.canvas.width)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                    Text(st.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .accentColor : .primary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    var c = model.config
                    c.clotheslineStyle = st == .default ? nil : st.rawValue
                    model.save(c)
                }
            }
        }
    }
}
