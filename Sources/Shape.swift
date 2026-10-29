import Cocoa

/// Shape-gesture recognition, reconstructed from the original app's behaviour
/// (see docs/ALGORITHMS_RECOVERED.md):
///
///   • strokes shorter than 30 pt score 0
///   • distance = arc-length weighted DTW between two strokes
///   • score    = max(0, 1 - 2.5 * d) * 100
///   • a gesture fires only when score > 85
///
/// We normalise both strokes to the unit box before the DTW so that the
/// template scale does not have to match the user's drawing exactly.
enum ShapeMatcher {

    static let scoreThreshold: Double = 85.0
    static let minSize: CGFloat = 30.0

    // MARK: - Stroke

    struct Stroke {
        var points: [CGPoint]
        var arc: [CGFloat]          // cumulative arc length per point
    }

    static func stroke(_ raw: [CGPoint]) -> Stroke? {
        guard raw.count >= 2 else { return nil }
        var pts: [CGPoint] = []
        for p in raw {
            if let last = pts.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { continue }
            pts.append(p)
        }
        guard pts.count >= 2 else { return nil }
        var arc: [CGFloat] = [0]
        var acc: CGFloat = 0
        for i in 1..<pts.count {
            acc += hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
            arc.append(acc)
        }
        guard acc > 0 else { return nil }
        return Stroke(points: pts, arc: arc)
    }

    /// Translate to origin and scale the longer side to 1.
    static func normalized(_ s: Stroke) -> Stroke {
        let xs = s.points.map(\.x), ys = s.points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let span = max(maxX - minX, maxY - minY)
        guard span > 0 else { return s }
        var pts = s.points.map { CGPoint(x: ($0.x - minX) / span, y: ($0.y - minY) / span) }
        // 等距重采样到 32 点，避免采样密度影响
        pts = resample(pts, count: 32)
        var arc: [CGFloat] = [0]
        var acc: CGFloat = 0
        for i in 1..<pts.count {
            acc += hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
            arc.append(acc)
        }
        return Stroke(points: pts, arc: arc)
    }

    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var acc: [CGFloat] = [0]
        for i in 1..<pts.count {
            acc.append(acc.last! + hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y))
        }
        let total = acc.last!
        guard total > 0 else { return Array(repeating: pts[0], count: count) }
        var out: [CGPoint] = []
        var j = 1
        for k in 0..<count {
            let target = total * CGFloat(k) / CGFloat(count - 1)
            while j < acc.count - 1 && acc[j] < target { j += 1 }
            let seg = acc[j] - acc[j-1]
            let t = seg > 0 ? (target - acc[j-1]) / seg : 0
            out.append(CGPoint(x: pts[j-1].x + (pts[j].x - pts[j-1].x) * t,
                               y: pts[j-1].y + (pts[j].y - pts[j-1].y) * t))
        }
        return out
    }

    // MARK: - Distance

    static func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        atan2(b.y - a.y, b.x - a.x)
    }

    static func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = abs(a - b)
        if d > .pi { d = 2 * .pi - d }
        return d / .pi          // 0…1
    }

    /// Arc-length weighted DTW. Returns a normalised distance (0 = identical).
    static func distance(_ a: Stroke, _ b: Stroke) -> Double {
        let n = a.points.count, m = b.points.count
        var dp = Array(repeating: Double.greatestFiniteMagnitude, count: n * m)
        for i in 0..<n {
            for j in 0..<m {
                let euclid = Double(hypot(a.points[i].x - b.points[j].x,
                                          a.points[i].y - b.points[j].y))
                // 方向惩罚：与前后点的夹角差
                var angleCost = 0.0
                if i > 0 && j > 0 {
                    let da = angleDelta(angle(a.points[i-1], a.points[i]),
                                        angle(b.points[j-1], b.points[j]))
                    angleCost = Double(da) * 0.6
                }
                let lenA = i > 0 ? Double(a.arc[i] - a.arc[i-1]) : 0
                let lenB = j > 0 ? Double(b.arc[j] - b.arc[j-1]) : 0
                let local = euclid + angleCost * (lenA + lenB) * 0.5

                if i == 0 && j == 0 { dp[0] = local; continue }
                var best = Double.greatestFiniteMagnitude
                if i > 0 { best = min(best, dp[(i-1)*m + j]) }
                if j > 0 { best = min(best, dp[i*m + (j-1)]) }
                if i > 0 && j > 0 { best = min(best, dp[(i-1)*m + (j-1)]) }
                dp[i*m + j] = local + best
            }
        }
        return dp[n*m - 1] / Double(n + m)
    }

    // MARK: - Score

    /// Returns 0…100, matching the original's scoring curve.
    ///
    /// Templates are tried at a few horizontal scales so a narrow/sloppy
    /// letter still matches, while arrows keep their direction (a horizontal
    /// line is unaffected by x scaling).
    static func score(template: [CGPoint], drawn: [CGPoint]) -> Double {
        guard let first = drawn.first else { return 0 }
        // 最小尺寸门限（原版 30 pt）
        let big = drawn.contains { abs($0.x - first.x) > minSize || abs($0.y - first.y) > minSize }
        guard big else { return 0 }
        guard let s2 = stroke(drawn) else { return 0 }
        let nd = normalized(s2)
        var best = 0.0
        for scale in [1.0, 0.78, 1.3] as [CGFloat] {
            let scaled = template.map { CGPoint(x: $0.x * scale, y: $0.y) }
            guard let s1 = stroke(scaled) else { continue }
            let d = distance(normalized(s1), nd)
            best = max(best, max(0, 1 - 2.5 * d) * 100)
        }
        return best
    }
}

// MARK: - Built-in glyph templates

/// The original app generates these procedurally (A–Z, `<`, `>`, 8 arrows).
/// We define the ones the default/user rules use; unknown glyphs return nil.
enum GlyphLibrary {

    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static func template(for glyph: String) -> [CGPoint]? {
        switch glyph {
        case "←": return [P(100, 50), P(0, 50)]
        case "→": return [P(0, 50), P(100, 50)]
        case "↑": return [P(50, 100), P(50, 0)]
        case "↓": return [P(50, 0), P(50, 100)]
        case "↖": return [P(100, 100), P(0, 0)]
        case "↗": return [P(0, 100), P(100, 0)]
        case "↙": return [P(100, 0), P(0, 100)]
        case "↘": return [P(0, 0), P(100, 100)]
        // Two-stroke polylines (上左 / 上右 / 下左 / 下右): first leg, then a right-angle turn.
        // ↑→ and ↓→ have the same shape as the letters F and L (see `polylineIDs`).
        case "↑←": return [P(100, 100), P(100, 0), P(0, 0)]
        case "↑→": return [P(0, 100), P(0, 0), P(100, 0)]
        case "↓←": return [P(100, 0), P(100, 100), P(0, 100)]
        case "↓→": return [P(0, 0), P(0, 100), P(100, 100)]
        // 上下：straight up, then back down the same line (default: refresh ⌘R)
        case "↑↓": return [P(50, 100), P(50, 0), P(50, 100)]
        case "<": return [P(100, 0), P(0, 50), P(100, 100)]
        case ">": return [P(0, 0), P(100, 50), P(0, 100)]
        case "A": return [P(0, 100), P(50, 0), P(100, 100)]
        case "V": return [P(0, 0), P(50, 100), P(100, 0)]
        case "T": return [P(0, 0), P(100, 0), P(50, 0), P(50, 100)]
        case "F": return [P(0, 100), P(0, 0), P(100, 0)]
        case "L": return [P(0, 0), P(0, 100), P(100, 100)]
        case "Z": return [P(0, 0), P(100, 0), P(0, 100), P(100, 100)]
        case "C": return [P(100, 0), P(50, 10), P(0, 50), P(50, 90), P(100, 100)]
        case "O": return [P(50, 0), P(10, 50), P(50, 100), P(90, 50), P(50, 0)]
        case "S": return [P(100, 0), P(20, 15), P(80, 50), P(20, 85), P(100, 100)]
        case "M": return [P(0, 100), P(0, 0), P(50, 60), P(100, 0), P(100, 100)]
        case "N": return [P(0, 100), P(0, 0), P(100, 100), P(100, 0)]
        case "U": return [P(0, 0), P(0, 80), P(50, 100), P(100, 80), P(100, 0)]
        case "W": return [P(0, 0), P(25, 100), P(50, 40), P(75, 100), P(100, 0)]
        case "H": return [P(0, 0), P(0, 100), P(0, 50), P(100, 50), P(100, 0), P(100, 100)]
        default: return nil
        }
    }

    /// `twoKey.<suffix>` → glyph: 4 straight lines, 4 diagonals, 4 two-stroke polylines.
    static let directionGlyphs: [String: String] = [
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "upLeft": "↖", "upRight": "↗", "downLeft": "↙", "downRight": "↘",
        "upThenLeft": "↑←", "upThenRight": "↑→", "downThenLeft": "↓←", "downThenRight": "↓→",
        "upThenDown": "↑↓",
    ]
    /// The two-stroke gestures. On an equal score they beat a letter of the same shape
    /// (↑→ = F, ↓→ = L) so a rule set with both behaves the same every time.
    static let polylineIDs: Set<String> = ["twoKey.upThenLeft", "twoKey.upThenRight",
                                           "twoKey.downThenLeft", "twoKey.downThenRight", "twoKey.upThenDown"]

    /// Templates to score a glyph against (best one counts). The two-stroke glyphs add a
    /// long-first and a short-first version: people rarely draw both legs the same length,
    /// and the matcher only absorbs ~1.3× of aspect change by itself.
    static func templates(for glyph: String) -> [[CGPoint]] {
        guard let t = template(for: glyph) else { return [] }
        guard glyph.count == 2, t.count == 3 else { return [t] }
        func leg(_ from: CGPoint, _ to: CGPoint, _ k: CGFloat) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
        }
        let corner = t[1]
        return [t,
                [t[0], corner, leg(corner, t[2], 0.45)],      // long first leg, short second
                [leg(corner, t[0], 0.45), corner, t[2]]]      // short first leg, long second
    }

    /// `twoKey.custom.<name>`: template comes from `Config.customGlyphs[name]`.
    static let customPrefix = "twoKey.custom."

    /// Gesture id → glyph character (see docs/ORIGINAL_FEATURES.md §3.1).
    static func glyph(forGestureID id: String) -> String? {
        if id.hasPrefix("twoKey.key.") {
            let c = String(id.dropFirst("twoKey.key.".count))
            return c.uppercased()
        }
        if id.hasPrefix("twoKey.") {
            return directionGlyphs[String(id.dropFirst("twoKey.".count))]
        }
        return nil
    }
}
