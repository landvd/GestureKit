import Foundation
import CoreGraphics

/// One finished gesture as the user drew it, what GestureKit took it for, and — once the
/// user rates it on the 「手势记录」 page — whether that was right.
struct GestureRecord: Codable, Identifiable, Equatable {
    enum Rating: String, Codable { case good, bad }

    var id = UUID()
    var time: Date
    var app: String                      // bundle id ("" unknown)
    var points: [CGPoint]                // relative to the first point, ≤ 64 (thumbnail + learning)
    var gestureID: String?               // what it matched (nil = nothing)
    var score: Double
    var via: Recognition.Via
    var action: String                   // what ran / would have run, for display
    var rating: Rating?
    /// For a 👎: the gesture the user meant (`GestureHistory.noneIntended` = 「不该触发」).
    var intended: String?
    var comment: String?

    var fired: Bool { via == .shape || via == .direction || via == .key }
}

/// The last `capacity` gestures, newest first; saved to history.json next to rules.json.
/// Main thread only. Learning itself lives in the config (`learnedStrokes` /
/// `rejectedStrokes`), so it travels with rules export and needs no history.
final class GestureHistory: ObservableObject {
    static let shared = GestureHistory(file: Config.configURL.deletingLastPathComponent()
                                        .appendingPathComponent("history.json"))
    static let capacity = 200
    static let noneIntended = "__none__"
    static let maxLearned = 5
    static let maxRejected = 10

    @Published private(set) var records: [GestureRecord] = []
    private let file: URL?
    private var saveScheduled = false

    /// `file: nil` = in memory only (selftest).
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([GestureRecord].self, from: data) {
            records = list
        }
    }

    func add(_ r: GestureRecord) {
        records.insert(r, at: 0)
        if records.count > GestureHistory.capacity { records.removeLast(records.count - GestureHistory.capacity) }
        scheduleSave()
    }

    func update(_ r: GestureRecord) {
        guard let i = records.firstIndex(where: { $0.id == r.id }) else { return }
        records[i] = r
        scheduleSave()
    }

    func clear() { records = []; scheduleSave() }

    /// Rated so far / of those, rated good — the 「准确率」 shown on the page.
    var stats: (rated: Int, good: Int, unrecognized: Int) {
        (records.filter { $0.rating != nil }.count, records.filter { $0.rating == .good }.count,
         records.filter { $0.via == .none }.count)
    }

    private func scheduleSave() {
        guard let file, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let snapshot = self.records
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
            }
        }
    }

    // MARK: - Pure helpers (selftest)

    /// A stroke for storing: relative to its first point, at most `limit` points.
    static func compact(_ pts: [CGPoint], limit: Int = 64) -> [CGPoint] {
        guard let o = pts.first else { return [] }
        let step = max(1, Int((Double(pts.count) / Double(limit)).rounded(.up)))
        var out = stride(from: 0, to: pts.count, by: step).map { CGPoint(x: pts[$0].x - o.x, y: pts[$0].y - o.y) }
        if let last = pts.last, (pts.count - 1) % step != 0 { out.append(CGPoint(x: last.x - o.x, y: last.y - o.y)) }
        return out
    }

    /// Apply a 👎 to the config: 「我想画的是 X」 teaches the stroke to X; 「不该触发」 records it
    /// as a counter-example of what fired. Returns the config unchanged when there is
    /// nothing to learn (no stroke, e.g. a chord + letter key gesture).
    static func learning(from r: GestureRecord, intended: String, into config: Config) -> Config {
        guard r.points.count >= 2 else { return config }
        var c = config
        if intended == noneIntended {
            guard let id = r.gestureID else { return config }
            var neg = c.rejectedStrokes ?? [:]
            neg[id, default: []].append(r.points)
            neg[id] = Array(neg[id]!.suffix(maxRejected))
            c.rejectedStrokes = neg
            // Not wanted for this gesture: no longer one of its taught samples either.
            c.learnedStrokes?[id]?.removeAll { $0 == r.points }
        } else {
            var pos = c.learnedStrokes ?? [:]
            // One stroke belongs to one gesture: teaching it to X takes it away from any other
            // gesture (the same stroke taught to both ↑→ and ↓→ made the pick random).
            for k in pos.keys where k != intended { pos[k]?.removeAll { $0 == r.points } }
            if !(pos[intended] ?? []).contains(r.points) { pos[intended, default: []].append(r.points) }
            pos[intended] = Array(pos[intended]!.suffix(maxLearned))
            c.learnedStrokes = pos.filter { !$0.value.isEmpty }
            // Taught as X: no longer a counter-example of X either.
            c.rejectedStrokes?[intended]?.removeAll { $0 == r.points }
        }
        return c
    }

    /// Learned samples that the history now says belong elsewhere — a stroke re-rated from
    /// 「下右」 to 「上右」 used to stay under both — are dropped: the latest rating wins.
    static func reconcile(_ config: Config, with records: [GestureRecord]) -> Config {
        var c = config
        guard var pos = c.learnedStrokes else { return config }
        for (id, strokes) in pos {
            pos[id] = strokes.filter { s in
                guard let r = records.first(where: { $0.points == s && $0.rating == .bad }),
                      let wanted = r.intended else { return true }
                return wanted == id
            }
        }
        c.learnedStrokes = pos.filter { !$0.value.isEmpty }
        return c
    }

    static func learnedCount(_ c: Config) -> (learned: Int, rejected: Int) {
        ((c.learnedStrokes ?? [:]).values.reduce(0) { $0 + $1.count },
         (c.rejectedStrokes ?? [:]).values.reduce(0) { $0 + $1.count })
    }
}
