import Cocoa

/// 截图衣架的数据（纯逻辑 + 本机文件）。界面在 ClotheslineWindow.swift。
///
/// 存放：`~/Library/Application Support/GestureKit/Clothesline/`（index.json + 每张一个 PNG），
/// 重启保留，只在本机。最多 `capacity` 张未固定的图，新图在右；超出时最旧的掉下去。
/// 固定的图挂在最左边，不被挤掉，也不计入上限。
final class ClotheslineStore {

    struct Item: Codable, Equatable {
        let id: String
        let file: String
        let created: Date
        var pinned: Bool
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: Double

        var pointSize: CGSize { CGSize(width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale) }
    }

    static let capacity = 20

    let dir: URL
    private(set) var items: [Item] = []

    static var defaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GestureKit/Clothesline")
    }

    init(dir: URL = ClotheslineStore.defaultDir) {
        self.dir = dir
        load()
        discardUndo()          // 上次退出前没来得及删的「已清空」图
    }

    /// 衣架上从左到右：固定的（按挂上的先后），然后其余（旧 → 新）
    var ordered: [Item] {
        items.filter(\.pinned).sorted { $0.created < $1.created }
            + items.filter { !$0.pinned }.sorted { $0.created < $1.created }
    }

    func url(_ item: Item) -> URL { dir.appendingPathComponent(item.file) }

    // MARK: - Changes

    /// 挂上一张（PNG 写进文件夹）；返回新条目
    @discardableResult
    func add(png: Data, pixelWidth: Int, pixelHeight: Int, scale: Double, date: Date = Date()) -> Item? {
        ensureDir()
        let id = UUID().uuidString
        let item = Item(id: id, file: "\(id).png", created: date, pinned: false,
                        pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
        do { try png.write(to: url(item)) } catch {
            Log.write("clothesline: write failed: \(error.localizedDescription)")
            return nil
        }
        items.append(item)
        dropOverflow()
        save()
        return item
    }

    private func dropOverflow() {
        let drop = ClotheslineStore.overflow(items)
        for old in drop { deleteFile(old) }
        items.removeAll { drop.contains($0) }
    }

    /// 超出上限时要掉下去的（最旧的未固定）
    static func overflow(_ items: [Item]) -> [Item] {
        let loose = items.filter { !$0.pinned }.sorted { $0.created < $1.created }
        return Array(loose.prefix(max(0, loose.count - capacity)))
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned = pinned
        if !pinned { dropOverflow() }
        save()
    }

    func remove(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        deleteFile(item)
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        for item in items { deleteFile(item) }
        items.removeAll()
        save()
    }

    // MARK: - 一键清空（可撤销）

    /// 撤销区：清空时图片先挪到这里，撤销就挪回去，过几秒 discardUndo() 再真正删
    var undoDir: URL { dir.appendingPathComponent("Undo") }

    /// 清掉所有未固定的图（固定的保留）；返回被清掉的条目，供撤销
    @discardableResult
    func clearUnpinned() -> [Item] {
        discardUndo()
        let gone = items.filter { !$0.pinned }
        guard !gone.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: undoDir, withIntermediateDirectories: true)
        for item in gone {
            try? FileManager.default.moveItem(at: url(item), to: undoDir.appendingPathComponent(item.file))
            try? FileManager.default.removeItem(at: dragDir(item))
        }
        items.removeAll { !$0.pinned }
        save()
        return gone
    }

    /// 撤销清空：图片挪回来、条目放回去（文件已不在的跳过）
    func restore(_ gone: [Item]) {
        for item in gone {
            let from = undoDir.appendingPathComponent(item.file)
            guard (try? FileManager.default.moveItem(at: from, to: url(item))) != nil else { continue }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        dropOverflow()
        save()
        discardUndo()
    }

    /// 撤销期过了：真正删掉
    func discardUndo() { try? FileManager.default.removeItem(at: undoDir) }

    // MARK: - Files

    private var indexURL: URL { dir.appendingPathComponent("index.json") }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Item].self, from: data) else { return }
        // 文件被删掉的条目丢掉
        items = list.filter { FileManager.default.fileExists(atPath: url($0).path) }
        if items.count != list.count { save() }
    }

    private func save() {
        ensureDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try enc.encode(items).write(to: indexURL, options: .atomic) } catch {
            Log.write("clothesline: save failed: \(error.localizedDescription)")
        }
    }

    /// 拖出 / 预览用的好名字副本放这里（取下时一起删）
    func dragDir(_ item: Item) -> URL { dir.appendingPathComponent("Drag").appendingPathComponent(item.id) }

    private func deleteFile(_ item: Item) {
        try? FileManager.default.removeItem(at: url(item))
        try? FileManager.default.removeItem(at: dragDir(item))
    }

    // MARK: - Images

    /// 衣架上用的小图（最长边 `maxPixels`），不把整张大图读进内存
    func thumbnail(_ item: Item, maxPixels: Int = 360) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url(item) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    func image(_ item: Item) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url(item) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// 衣架的几何：卡片大小、位置、绳子的弧度（纯函数）。
/// 坐标：衣架面板内，左上原点，单位点。
enum ClotheslineLayout {

    static let maxCardHeight: CGFloat = 84
    static let minCardHeight: CGFloat = 44
    static let maxCardWidth: CGFloat = 130
    static let gap: CGFloat = 16
    static let margin: CGFloat = 36
    /// 绳子最低点比两端低多少
    static let sag: CGFloat = 10
    /// 绳子两端的 y
    static let lineY: CGFloat = 14
    /// 卡片顶端比绳子低多少（夹子的位置）
    static let clipDrop: CGFloat = 6

    /// 绳子在 x 处的 y（抛物线，两端 lineY，中间 lineY + sag）
    static func lineY(at x: CGFloat, width: CGFloat, sag: CGFloat = sag) -> CGFloat {
        guard width > 0 else { return lineY }
        let t = (x / width) * 2 - 1           // -1 … 1
        return lineY + sag * (1 - t * t)
    }

    /// 每张卡片的框（按给定的宽高比），整体在面板内水平居中，挂在绳子上。
    /// 卡片太多放不下时整体缩小（不低于 minCardHeight）。
    static func frames(aspects: [CGFloat], width: CGFloat, sag: CGFloat = sag) -> [CGRect] {
        guard !aspects.isEmpty else { return [] }
        let a = aspects.map { min(max($0, 0.4), 3) }
        func size(_ h: CGFloat, _ r: CGFloat) -> CGSize {
            let w = min(h * r, maxCardWidth * h / maxCardHeight)
            return CGSize(width: w, height: w / r)
        }
        let avail = width - margin * 2
        var h = maxCardHeight
        while h > minCardHeight {
            let total = a.reduce(0) { $0 + size(h, $1).width } + gap * CGFloat(a.count - 1)
            if total <= avail { break }
            h -= 2
        }
        let sizes = a.map { size(h, $0) }
        let sum = sizes.reduce(0) { $0 + $1.width }
        // 最小尺寸仍放不下：收窄间距，再不够就让卡片挤在一起（部分重叠）
        var spacing = gap
        if sizes.count > 1, sum + gap * CGFloat(sizes.count - 1) > avail {
            spacing = (avail - sum) / CGFloat(sizes.count - 1)
        }
        let total = sum + spacing * CGFloat(sizes.count - 1)
        var x = max(margin, (width - total) / 2)
        return sizes.map { s in
            let top = lineY(at: x + s.width / 2, width: width, sag: sag) + clipDrop
            defer { x += s.width + spacing }
            return CGRect(x: x, y: top, width: s.width, height: s.height)
        }
    }

    /// 面板宽度：屏宽的 60%，卡片多时放到 90%
    static func panelWidth(screenWidth: CGFloat, count: Int) -> CGFloat {
        let want = margin * 2 + CGFloat(max(count, 4)) * (maxCardWidth * 0.75 + gap)
        return min(max(screenWidth * 0.6, want), screenWidth * 0.9)
    }

    static let panelHeight: CGFloat = lineY + sag + clipDrop + maxCardHeight + 28
}

/// 「鼠标停在菜单栏正中」的判定（纯逻辑）。
enum ClotheslineTrigger {

    static let zoneWidth: CGFloat = 160
    static let dwell: TimeInterval = 0.3
    static let leaveDelay: TimeInterval = 0.7

    /// 一块屏幕顶端正中的热区（Cocoa 坐标）。菜单栏隐藏时按 24pt 高算。
    static func zone(screen: CGRect, visible: CGRect) -> CGRect {
        let bar = max(screen.maxY - visible.maxY, 24)
        return CGRect(x: screen.midX - zoneWidth / 2, y: screen.maxY - bar, width: zoneWidth, height: bar)
    }
}

/// 衣架样式（纯参数）。木夹麻绳是缺省；配置里存 rawValue。
enum ClotheslineStyle: String, CaseIterable {
    case wood, polaroid, binder, plastic, tape

    static let `default` = ClotheslineStyle.wood

    init(config: String?) { self = ClotheslineStyle(rawValue: config ?? "") ?? .default }

    var title: String {
        switch self {
        case .wood:     return L("木夹麻绳")
        case .polaroid: return L("拍立得")
        case .binder:   return L("长尾夹钢丝")
        case .plastic:  return L("彩色塑料夹")
        case .tape:     return L("和纸胶带")
        }
    }

    enum Fastener: Equatable { case woodClip, binderClip, plasticClip, tape }

    var fastener: Fastener {
        switch self {
        case .wood, .polaroid: return .woodClip
        case .binder:          return .binderClip
        case .plastic:         return .plasticClip
        case .tape:            return .tape
        }
    }

    /// 绳子下垂多少（钢丝是直的）
    var sag: CGFloat { self == .binder ? 0 : ClotheslineLayout.sag }
    /// 静止时最多歪几度
    var maxTilt: CGFloat { self == .binder ? 1 : 2 }
    /// 相框留白：左右 / 上 / 下（拍立得下边留宽，写时间）
    var mat: (side: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch self {
        case .wood, .plastic: return (3, 3, 3)
        case .polaroid:       return (5, 5, 18)
        case .binder, .tape:  return (0, 0, 0)
        }
    }
    var cornerRadius: CGFloat { self == .plastic ? 6 : (self == .binder || self == .tape ? 1 : 2) }
    /// 拍立得在下边写截图时间
    var showsTime: Bool { self == .polaroid }

    /// 卡片外框的宽高比：照片按 image 比例、高度按满尺寸卡片估算，再加上留白
    func outerAspect(_ imageAspect: CGFloat) -> CGFloat {
        let h = ClotheslineLayout.maxCardHeight
        let photoH = h - mat.top - mat.bottom
        return (photoH * imageAspect + mat.side * 2) / h
    }

    /// 塑料夹 / 胶带的颜色：按 id 固定挑一个（马卡龙色）
    static let candy: [(CGFloat, CGFloat, CGFloat)] = [
        (0.93, 0.58, 0.69), (0.36, 0.79, 0.65), (0.98, 0.78, 0.46), (0.52, 0.72, 0.92), (0.69, 0.66, 0.93),
    ]
    static func candyIndex(_ id: String) -> Int {
        Int(id.unicodeScalars.reduce(UInt32(5)) { ($0 &* 33) &+ $1.value } % UInt32(candy.count))
    }
}
