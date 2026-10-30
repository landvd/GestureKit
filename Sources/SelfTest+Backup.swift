import Foundation

// 规则自动备份的自检；文件操作只在临时目录，绝不读写 ~/Library/Application Support/GestureKit/。
extension SelfTest {

    // MARK: - 自动备份轮换（临时目录）

    static func backupChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gk-autobackup-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rules.json")
        func list() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
        func day(_ n: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: n, hour: 12))!
        }

        check("autobackup: missing rules.json → no backup", ConfigIO.autoBackup(file, now: day(1)) == nil && list().isEmpty)

        try? Data("v1".utf8).write(to: file)
        let others = ["rules.backup-20260301-120000.json", "rules.broken-20260101-000000.json",
                      "rules.auto-notadate.json", "rules.auto-20260301.json.bak", "notes.txt"]
        for o in others { try? Data("keep".utf8).write(to: dir.appendingPathComponent(o)) }

        let first = ConfigIO.autoBackup(file, now: day(1))
        try? Data("v2".utf8).write(to: file)
        let second = ConfigIO.autoBackup(file, now: day(1))
        let copy = first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        check("autobackup: once per day, copies the pre-save content",
              first?.lastPathComponent == "rules.auto-20260301.json" && second == nil && copy == "v1",
              "\(list())")

        for d in 2...7 { ConfigIO.autoBackup(file, now: day(d)) }
        let autos = list().filter { ConfigIO.isAutoBackup($0, of: file) }
        check("autobackup: keeps the newest 5, deletes the oldest",
              autos == (3...7).map { String(format: "rules.auto-202603%02d.json", $0) }, "\(autos)")
        check("autobackup: never touches other files",
              others.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
              && (try? String(contentsOf: file, encoding: .utf8)) == "v2")
        check("autobackup: name filter",
              ConfigIO.isAutoBackup("rules.auto-20260101.json", of: file)
              && !ConfigIO.isAutoBackup("rules.auto-2026010.json", of: file)
              && !ConfigIO.isAutoBackup("rules.backup-20260101.json", of: file)
              && !ConfigIO.isAutoBackup("other.auto-20260101.json", of: file))
        return out
    }
}
