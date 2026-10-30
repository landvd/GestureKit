import Foundation
import CoreGraphics

/// `--replay-history`: read-only. Runs every stroke in history.json through the current
/// recognizer with the current rules (per the app it was drawn in), and prints the top
/// candidates — the data for tuning recognition from real use. The user's ratings are the
/// ground truth where present (👎 + 「我想画的是 X」 → X; 👍 → what fired).
enum HistoryReplay {

    struct Outcome {
        var record: GestureRecord
        var now: Recognition
        var expected: String?         // what the user wanted, when known
        var candidates: [(id: String, score: Double)]
    }

    static func expected(_ r: GestureRecord) -> String? {
        switch r.rating {
        case .good?: return r.gestureID
        case .bad?:  return r.intended == GestureHistory.noneIntended ? GestureHistory.noneIntended : r.intended
        case nil:    return nil
        }
    }

    static func replay(_ records: [GestureRecord], config: Config) -> [Outcome] {
        records.filter { $0.points.count >= 2 }.map { r in
            let rules = GestureEngine.effectiveRules(config, app: r.app)
            let now = Recognizer.recognize(points: r.points, rules: rules, config: config)
            let cands = rules.gestures.keys.compactMap { id -> (String, Double)? in
                let t = Recognizer.shapeTemplates(forGestureID: id, config: config)
                guard !t.isEmpty else { return nil }
                return (id, t.map { ShapeMatcher.score(template: $0, drawn: r.points) }.max() ?? 0)
            }.sorted { $0.1 > $1.1 }
            return Outcome(record: r, now: now, expected: expected(r), candidates: Array(cands.prefix(3)))
        }
    }

    static func run() -> Int32 {
        let file = Config.configURL.deletingLastPathComponent().appendingPathComponent("history.json")
        let history = GestureHistory(file: file)
        let config = GestureHistory.reconcile(Config.loadOrCreate(), with: history.records)   // as the app does at launch
        let out = replay(history.records, config: config)
        func name(_ id: String?) -> String {
            guard let id else { return "—" }
            return id == GestureHistory.noneIntended ? L("不该触发任何动作") : PrefModel.shortGestureName(id)
        }
        var fired = 0, rightWhenKnown = 0, known = 0
        for o in out {
            let r = o.record
            if o.now.fires { fired += 1 }
            var mark = " "
            if let e = o.expected {
                known += 1
                let ok = e == GestureHistory.noneIntended ? !o.now.fires : (o.now.fires && o.now.gestureID == e)
                if ok { rightWhenKnown += 1 }
                mark = ok ? "✓" : "✗"
            }
            let cands = o.candidates.map { "\(name($0.id)) \(Int($0.score))" }.joined(separator: ", ")
            print("\(mark) \(r.app.split(separator: ".").last ?? "")  当时 \(r.via.rawValue) \(name(r.gestureID)) \(Int(r.score))"
                  + "  →  现在 \(o.now.via.rawValue) \(name(o.now.gestureID)) \(Int(o.now.score))"
                  + "  [\(cands)]" + (o.expected.map { "  想要 \(name($0))" } ?? ""))
        }
        let thenFired = out.filter { $0.record.fired }.count
        let unsureThen = out.filter { $0.record.via == .unsure }.count, unsureNow = out.filter { $0.now.via == .unsure }.count
        print("共 \(out.count) 笔：当时执行 \(thenFired) 笔 → 现在会执行 \(fired) 笔；「把握不足」当时 \(unsureThen) → 现在 \(unsureNow)；"
              + "有评价的 \(known) 笔里现在正确 \(rightWhenKnown) 笔")
        return 0
    }
}
