import Foundation

/// One assertion from a feature's selftest suite. Each P2 area owns one
/// `SelfTest+<Area>.swift` file returning its checks, so areas can be worked
/// on independently without editing main.swift.
struct SelfTestCheck {
    let name: String
    let ok: Bool
    var detail: String = ""
}

extension SelfTest {
    /// Run in this order after the built-in checks in `SelfTest.run()`.
    static var suites: [(String, () -> [SelfTestCheck])] {
        [("actions", actionChecks), ("buttons", buttonChecks), ("linkDrag", linkDragChecks), ("smoothScroll", smoothScrollChecks), ("permissions", permissionChecks),
         ("i18n", i18nChecks),
         ("backup", backupChecks), ("actionsExt", actionExtChecks), ("ddc", ddcChecks), ("chord", chordChecks), ("history", historyChecks), ("perf", perfChecks)]
    }
}
