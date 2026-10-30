import Foundation

/// Import / export / reset of rules.json.
/// Every destructive step first copies the current file to a timestamped backup.
enum ConfigIO {

    enum ImportMode { case replace, merge }

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func export(_ config: Config, to url: URL) throws {
        try JSONEncoder.pretty.encode(config).write(to: url, options: .atomic)
    }

    static func decode(_ data: Data) throws -> Config {
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ImportError(message: L("不是有效的 GestureKit 规则文件（%@）", error.localizedDescription))
        }
    }

    /// replace: the file becomes the config.
    /// merge: rules from the file are added on top; same gesture id → the file wins.
    /// Global switches (enabled, thresholds, HUD) stay as they are.
    static func combine(current: Config, imported: Config, mode: ImportMode) -> Config {
        guard mode == .merge else { return imported }
        var c = current
        for (app, rs) in imported.rulesets {
            var gestures = c.rulesets[app]?.gestures ?? [:]
            for (id, spec) in rs.gestures { gestures[id] = spec }
            c.rulesets[app] = Ruleset(gestures: gestures)
        }
        var black = c.blacklist ?? []
        for id in imported.blacklist ?? [] where !black.contains(id) { black.append(id) }
        c.blacklist = black
        if let glyphs = imported.customGlyphs {
            var mine = c.customGlyphs ?? [:]
            for (k, v) in glyphs { mine[k] = v }
            c.customGlyphs = mine
        }
        return c
    }

    /// Copy `file` next to itself as `<name>.<tag>-<timestamp>.json`. Returns the copy.
    @discardableResult
    static func backup(_ file: URL = Config.configURL, tag: String = "backup") -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = file.deletingPathExtension().lastPathComponent
        let dest = file.deletingLastPathComponent()
            .appendingPathComponent("\(name).\(tag)-\(f.string(from: Date())).json")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: file, to: dest)
            return dest
        } catch {
            Log.write("backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: 自动备份轮换（每天最多一份，保留最近 `keep` 份）

    static let autoBackupKeep = 5

    /// `rules.auto-yyyyMMdd.json` 的文件名（本地时区）。
    static func autoBackupName(for file: URL, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return "\(file.deletingPathExtension().lastPathComponent).auto-\(f.string(from: date)).json"
    }

    /// 是否是本功能产生的自动备份（`<name>.auto-<8 位数字>.json`）——只有它们会被轮换删除。
    static func isAutoBackup(_ fileName: String, of file: URL) -> Bool {
        let prefix = "\(file.deletingPathExtension().lastPathComponent).auto-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".json") else { return false }
        let mid = fileName.dropFirst(prefix.count).dropLast(".json".count)
        return mid.count == 8 && mid.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 保存前调用：当天还没有自动备份时把 `file`（保存前的内容）复制为
    /// `rules.auto-<今天>.json`，然后只保留最近 `keep` 份 `rules.auto-*.json`。
    /// 目录与日期可注入（自检用临时目录）。返回新建的备份；当天已有或文件不存在 → nil。
    @discardableResult
    static func autoBackup(_ file: URL = Config.configURL, now: Date = Date(),
                           keep: Int = autoBackupKeep) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }
        let dir = file.deletingLastPathComponent()
        let dest = dir.appendingPathComponent(autoBackupName(for: file, date: now))
        guard !fm.fileExists(atPath: dest.path) else { return nil }
        do {
            try fm.copyItem(at: file, to: dest)
        } catch {
            Log.write("auto backup failed: \(error.localizedDescription)")
            return nil
        }
        pruneAutoBackups(of: file, keep: keep)
        return dest
    }

    /// 删除多余的自动备份（按文件名里的日期，旧的先删）。绝不碰其它文件。
    static func pruneAutoBackups(of file: URL, keep: Int = autoBackupKeep) {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let autos = names.filter { isAutoBackup($0, of: file) }.sorted(by: >)   // 新 → 旧
        for name in autos.dropFirst(max(keep, 1)) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

extension Config {
    /// Drop recorded strokes that no rule references any more.
    mutating func pruneCustomGlyphs() {
        guard let glyphs = customGlyphs, !glyphs.isEmpty else { return }
        let p = GlyphLibrary.customPrefix
        let used = Set(rulesets.values.flatMap { $0.gestures.keys }
            .filter { $0.hasPrefix(p) }.map { String($0.dropFirst(p.count)) })
        customGlyphs = glyphs.filter { used.contains($0.key) }
    }

    /// Smallest positive integer not yet used as a custom glyph name.
    func nextCustomGlyphName() -> String {
        var n = 1
        while customGlyphs?["\(n)"] != nil { n += 1 }
        return "\(n)"
    }
}
