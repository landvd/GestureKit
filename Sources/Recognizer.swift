import CoreGraphics
import Foundation

/// What one finished stroke was taken for. Pure: built from a snapshot of the rules and
/// config on the recognition queue, then used both to run the action and to write the
/// gesture history (手势记录).
struct Recognition {
    enum Via: String, Codable {
        case shape          // matched a glyph / custom / learned stroke
        case direction      // no shape, but a clearly straight stroke → ←/→/↑/↓ rule
        case key            // chord + letter key (no stroke to judge)
        case none           // nothing matched → 「未识别」
        case rejected       // matched, but looks like a stroke the user said must not fire
        case unsure         // dangerous action (quit / close) without enough confidence
    }
    var gestureID: String?
    var spec: ActionSpec?
    var score: Double
    var via: Via

    /// Runs an action only for these.
    var fires: Bool { spec != nil && (via == .shape || via == .direction || via == .key) }
}

enum Recognizer {

    /// Quitting / closing need a surer match than the 85 the other gestures use. 92 turned
    /// out too strict in real use (the user's own 「<」 / 「上右」 scored 85–92 and were
    /// rated 「正常手势」), so 88 — and none at all once the stroke matches a sample the
    /// user taught that gesture.
    static let dangerThreshold = 88.0

    static func isDangerous(_ spec: ActionSpec) -> Bool {
        let cmd: UInt32 = 0x00100000
        switch spec.type {
        case "quitApp": return true
        case "shortcut":
            // ⌘Q quit, ⌘W close tab/window
            return (spec.modifiers ?? 0) & cmd != 0 && [12, 13].contains(spec.keyCode ?? -1)
        case "system":  return ["closeTab", "closeWindow", "forceQuit", "shutdown", "restart"].contains(spec.op ?? "")
        default:        return false
        }
    }

    /// A stroke that is a line, not a shape: the start→end distance is most of the path
    /// and long enough. Only then may an unmatched stroke fall back to its direction —
    /// a sloppy ↑↓ or letter ends near its start and used to fire 后退 / 前进 by accident.
    static func isStraight(_ pts: [CGPoint], minLength: CGFloat) -> Bool {
        guard let a = pts.first, let b = pts.last, pts.count >= 2 else { return false }
        var path: CGFloat = 0
        for i in 1..<pts.count { path += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        let chord = hypot(b.x - a.x, b.y - a.y)
        return chord >= minLength && chord >= 0.8 * path
    }

    static func recognize(points: [CGPoint], rules: Ruleset, config: Config) -> Recognition {
        let threshold = config.shapeThreshold ?? ShapeMatcher.scoreThreshold
        if let best = bestShape(points: points, rules: rules, config: config), best.score > threshold {
            if matchesRejected(points, id: best.id, config: config, threshold: threshold) {
                return Recognition(gestureID: best.id, spec: best.spec, score: best.score, via: .rejected)
            }
            if isDangerous(best.spec), !best.taught, best.score < max(threshold, dangerThreshold) {
                return Recognition(gestureID: best.id, spec: best.spec, score: best.score, via: .unsure)
            }
            return Recognition(gestureID: best.id, spec: best.spec, score: best.score, via: .shape)
        }
        // 回退：纯方向判定（只对明显的直线）
        if isStraight(points, minLength: max(40, CGFloat(config.minDistance) * 1.5)),
           let a = points.first, let b = points.last {
            let id = "twoKey." + direction(from: a, to: b)
            if let spec = rules.gestures[id] {
                if matchesRejected(points, id: id, config: config, threshold: threshold) {
                    return Recognition(gestureID: id, spec: spec, score: 0, via: .rejected)
                }
                return Recognition(gestureID: id, spec: spec, score: 0, via: .direction)
            }
        }
        return Recognition(gestureID: nil, spec: nil, score: 0, via: .none)
    }

    static func direction(from a: CGPoint, to b: CGPoint) -> String {
        let dx = b.x - a.x
        let dy = b.y - a.y                       // CG coordinates: +y is down
        if abs(dx) > 2 * abs(dy) { return dx < 0 ? "left" : "right" }
        if abs(dy) > 2 * abs(dx) { return dy < 0 ? "up" : "down" }
        if dx < 0 { return dy < 0 ? "upLeft" : "downLeft" }
        return dy < 0 ? "upRight" : "downRight"
    }

    // MARK: - Shapes

    /// Best-scoring rule. `taught`: the score came from a stroke the user taught this gesture.
    /// Ties never depend on dictionary order: polyline over letter (↑→ = F, ↓→ = L), then a
    /// taught match over a built-in one, then the id.
    private static func bestShape(points: [CGPoint], rules: Ruleset, config: Config)
        -> (id: String, spec: ActionSpec, score: Double, taught: Bool)? {
        guard points.count >= 2 else { return nil }
        typealias Cand = (id: String, spec: ActionSpec, score: Double, polyline: Bool, taught: Bool)
        func better(_ a: Cand, than b: Cand) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.polyline != b.polyline { return a.polyline }
            if a.taught != b.taught { return a.taught }
            return a.id < b.id
        }
        var best: Cand?
        for (id, spec) in rules.gestures {
            let templates = shapeTemplates(forGestureID: id, config: config)
            guard !templates.isEmpty else { continue }
            let s = templates.map { ShapeMatcher.score(template: $0, drawn: points) }.max() ?? 0
            let learned = (config.learnedStrokes?[id] ?? []).map { ShapeMatcher.score(template: $0, drawn: points) }.max() ?? 0
            let c: Cand = (id, spec, s, GlyphLibrary.polylineIDs.contains(id), learned > 0 && learned >= s)
            if best == nil || better(c, than: best!) { best = c }
        }
        return best.map { ($0.id, $0.spec, $0.score, $0.taught) }
    }

    /// Built-in glyph (with its variants) or a drawn custom shape, plus the strokes the
    /// user taught it from the gesture history (「我想画的是…」).
    static func shapeTemplates(forGestureID id: String, config: Config) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        if id.hasPrefix(GlyphLibrary.customPrefix) {
            if let g = config.customGlyphs?[String(id.dropFirst(GlyphLibrary.customPrefix.count))] { out.append(g) }
        } else if let glyph = GlyphLibrary.glyph(forGestureID: id) {
            out = GlyphLibrary.templates(for: glyph)
        }
        if !out.isEmpty || id.hasPrefix("twoKey.") { out += config.learnedStrokes?[id] ?? [] }
        return out
    }

    /// The user said a stroke like this must not fire `id` (「不该触发」).
    private static func matchesRejected(_ points: [CGPoint], id: String, config: Config, threshold: Double) -> Bool {
        guard let negatives = config.rejectedStrokes?[id], !negatives.isEmpty else { return false }
        return negatives.contains { ShapeMatcher.score(template: $0, drawn: points) > threshold }
    }
}
