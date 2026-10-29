import SwiftUI

// MARK: - 手势记录 page

/// Recent gestures with a 👍 / 👎 each. A 👎 says what was meant (taught to that gesture)
/// or that nothing should have fired (kept as a counter-example), plus an optional comment.
struct HistoryPage: View {
    @ObservedObject var model: PrefModel
    @ObservedObject var history: GestureHistory

    var body: some View {
        VStack(spacing: 24) {
            summaryCard
            listCard
        }
        .sheet(item: $model.ratingDraft) { draft in
            RatingSheet(model: model, draft: draft)
        }
    }

    private var summaryCard: some View {
        let s = history.stats
        let l = GestureHistory.learnedCount(model.config)
        return HistoryCard(title: L("手势记录"), symbol: "clock.arrow.circlepath", tint: UI.accent) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("最近 %d 次手势 · 已评价 %d 次（正确 %d） · 未识别 %d 次",
                       history.records.count, s.rated, s.good, s.unrecognized))
                    .font(.system(size: 12))
                Text(L("已学会 %d 个笔画，记住 %d 个「不该触发」的笔画", l.learned, l.rejected))
                    .font(.system(size: 12)).foregroundColor(UI.secondary)
                Text(L("*画错或误触时点 👎：选「我想画的是…」，以后类似的画法会认成它；选「不该触发」，以后类似的画法不再触发。记录只保存在本机。"))
                    .font(.system(size: 10)).foregroundColor(UI.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L("清除学习数据")) { model.clearLearning() }
                        .buttonStyle(.bordered).disabled(l.learned + l.rejected == 0)
                    Button(L("清空记录")) { history.clear() }
                        .buttonStyle(.bordered).disabled(history.records.isEmpty)
                }
            }
        }
    }

    private var listCard: some View {
        HistoryCard(title: L("最近的手势"), symbol: "list.bullet", tint: .purple) {
            if history.records.isEmpty {
                Text(L("还没有记录。按住右键画一个手势试试。"))
                    .font(.system(size: 12)).foregroundColor(UI.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(history.records) { r in
                        HistoryRow(model: model, record: r)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    @ObservedObject var model: PrefModel
    let record: GestureRecord

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            StrokeThumb(points: record.points, faded: !record.fired)
                .frame(width: 46, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(PrefModel.historyResult(record))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(record.fired ? .primary : UI.danger)
                    .lineLimit(1)
                Text("\(HistoryRow.timeFormat.string(from: record.time))  ·  \(model.appTitle(record.app.isEmpty ? "default" : record.app))"
                     + (record.score > 0 ? "  ·  " + L("%d 分", Int(record.score.rounded())) : ""))
                    .font(.system(size: 10)).foregroundColor(UI.secondary)
                    .lineLimit(1)
                if let c = record.comment, !c.isEmpty {
                    Text("💬 " + c).font(.system(size: 10)).foregroundColor(UI.secondary).lineLimit(1)
                }
            }
            Spacer()
            rateButton("hand.thumbsup.fill", on: record.rating == .good, color: UI.ok,
                       label: L("正确")) { model.rateGood(record) }
            rateButton("hand.thumbsdown.fill", on: record.rating == .bad, color: UI.danger,
                       label: L("错误")) { model.ratingDraft = RatingDraft(record: record) }
        }
        .padding(.vertical, 7)
    }

    private func rateButton(_ symbol: String, on: Bool, color: Color, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(on ? .white : UI.secondary)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? color : Color.white.opacity(0.7)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// The stroke, scaled into the box (CG coordinates: +y down, like the screen).
private struct StrokeThumb: View {
    let points: [CGPoint]
    let faded: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.75))
            if points.count >= 2 {
                Canvas { ctx, size in
                    let xs = points.map(\.x), ys = points.map(\.y)
                    let w = max(xs.max()! - xs.min()!, 1), h = max(ys.max()! - ys.min()!, 1)
                    let k = min((size.width - 10) / w, (size.height - 10) / h)
                    let ox = (size.width - w * k) / 2 - xs.min()! * k, oy = (size.height - h * k) / 2 - ys.min()! * k
                    var p = Path()
                    p.addLines(points.map { CGPoint(x: $0.x * k + ox, y: $0.y * k + oy) })
                    ctx.stroke(p, with: .color(faded ? UI.secondary : UI.accent),
                               style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    if let s = points.first {
                        let c = CGPoint(x: s.x * k + ox, y: s.y * k + oy)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)),
                                 with: .color(faded ? UI.secondary : UI.accent))
                    }
                }
            } else {
                Image(systemName: "keyboard").font(.system(size: 13)).foregroundColor(UI.secondary)
            }
        }
    }
}

// MARK: - 👎 sheet

struct RatingDraft: Identifiable {
    let record: GestureRecord
    var id: UUID { record.id }
}

/// Editor state lives in an ObservableObject (`@State` needs the macro plugin).
final class RatingSheetState: ObservableObject {
    @Published var intended: String
    @Published var comment: String
    init(_ r: GestureRecord) {
        intended = r.intended ?? (r.fired ? GestureHistory.noneIntended : "")
        comment = r.comment ?? ""
    }
}

private struct RatingSheet: View {
    @ObservedObject var model: PrefModel
    let draft: RatingDraft
    @ObservedObject private var state: RatingSheetState

    init(model: PrefModel, draft: RatingDraft) {
        self.model = model
        self.draft = draft
        _state = ObservedObject(wrappedValue: RatingSheetState(draft.record))
    }

    var body: some View {
        let r = draft.record
        VStack(alignment: .leading, spacing: 16) {
            Text(L("这次手势哪里不对？")).font(.system(size: 15, weight: .semibold))
            HStack(spacing: 12) {
                StrokeThumb(points: r.points, faded: false).frame(width: 64, height: 48)
                Text(PrefModel.historyResult(r)).font(.system(size: 12))
            }
            if r.points.count >= 2 {
                HStack {
                    Text(L("我想要的是："))
                    Picker("", selection: $state.intended) {
                        Text(L("请选择")).tag("")
                        Text(L("不该触发任何动作")).tag(GestureHistory.noneIntended)
                        Divider()
                        ForEach(model.intendedOptions, id: \.id) { Text($0.title).tag($0.id) }
                    }.labelsHidden().frame(width: 240)
                }
                Text(state.intended == GestureHistory.noneIntended
                     ? L("*以后类似的画法不再触发「%@」", PrefModel.shortGestureName(r.gestureID ?? ""))
                     : L("*这一笔会存成你选的手势的个人样本，以后类似的画法直接认成它"))
                    .font(.system(size: 10)).foregroundColor(UI.secondary)
            } else {
                Text(L("*这是「按住右键 + 字母键」触发的，没有笔画可学，只记录评价"))
                    .font(.system(size: 10)).foregroundColor(UI.secondary)
            }
            HStack {
                Text(L("评价："))
                TextField(L("可选：说说发生了什么"), text: $state.comment).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(L("取消")) { model.ratingDraft = nil }.keyboardShortcut(.cancelAction)
                Button(L("提交")) {
                    model.rateBad(r, intended: state.intended.isEmpty ? nil : state.intended,
                                  comment: state.comment)
                    model.ratingDraft = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(r.points.count >= 2 && state.intended.isEmpty && state.comment.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Same look as the settings cards (that helper is private to PreferencesView).
private struct HistoryCard<C: View>: View {
    let title: String, symbol: String, tint: Color
    @ViewBuilder let content: () -> C
    init(title: String, symbol: String, tint: Color, @ViewBuilder content: @escaping () -> C) {
        self.title = title; self.symbol = symbol; self.tint = tint; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint).frame(width: 22, height: 22)
                    .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundColor(.white))
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            content()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous).fill(UI.cardBG))
    }
}

// MARK: - Model side

extension PrefModel {
    /// 「上下 ↑↓ → 刷新」/「未识别」/「把握不足：退出当前 App」…
    static func historyResult(_ r: GestureRecord) -> String {
        let name = shortGestureName(r.gestureID ?? "")
        switch r.via {
        case .shape, .direction, .key: return "\(name) → \(r.action)"
        case .none:     return L("未识别")
        case .unsure:   return L("%@ → 把握不足，未执行「%@」", name, r.action)
        case .rejected: return L("%@ → 已按反馈忽略「%@」", name, r.action)
        }
    }

    /// Gesture name without the 「按住右键 + 」 prefix.
    static func shortGestureName(_ id: String) -> String {
        let full = gestureName(id), prefix = L("按住右键 + ")
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    /// Gestures a stroke can be taught to: every 普通鼠标 gesture plus drawn custom shapes.
    var intendedOptions: [(id: String, title: String)] {
        let builtIn = RuleDraft.gestureOptions(for: .normalMouse).filter { $0.id != RuleDraft.customChoice }
        let customs = Set(config.rulesets.values.flatMap { $0.gestures.keys }
            .filter { $0.hasPrefix(GlyphLibrary.customPrefix) }).sorted()
        return (builtIn + customs.map { ($0, PrefModel.gestureName($0)) })
            .map { ($0.id, PrefModel.shortGestureName($0.id)) }
    }

    func rateGood(_ r: GestureRecord) {
        var r = r
        r.rating = r.rating == .good ? nil : .good          // click again to undo
        r.intended = nil
        history.update(r)
    }

    /// 👎 with what was meant (nil = only a comment). Teaching changes the rules, so it is saved.
    func rateBad(_ r: GestureRecord, intended: String?, comment: String) {
        var r = r
        r.rating = .bad
        r.intended = intended
        r.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : comment
        history.update(r)
        Log.write("history: rated bad \(r.gestureID ?? "none") intended=\(intended ?? "-")")
        if let intended {
            let c = GestureHistory.learning(from: r, intended: intended, into: config)
            if GestureHistory.learnedCount(c) != GestureHistory.learnedCount(config) { save(c) }
        }
    }

    func clearLearning() {
        let a = NSAlert()
        let n = GestureHistory.learnedCount(config)
        a.messageText = L("清除全部学习数据？")
        a.informativeText = L("会忘掉 %d 个学会的笔画和 %d 个「不该触发」的笔画，识别回到出厂状态。", n.learned, n.rejected)
        a.addButton(withTitle: L("清除"))
        a.addButton(withTitle: L("取消"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var c = config
        c.learnedStrokes = nil
        c.rejectedStrokes = nil
        save(c)
    }
}
