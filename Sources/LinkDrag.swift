import Cocoa

/// Safari: drag a link and drop it inside the page → open it in a new tab.
///
/// Observation only: the tap never swallows the drag, Safari handles it as usual. The check
/// runs after the release on a background queue (AX is slow), and only for a real drag, so
/// plain clicks cost nothing. Drops outside the page (tab bar, bookmarks, Desktop) and on
/// text fields are left to Safari. The URL is never logged.
enum LinkDrag {
    static let bundleID = "com.apple.Safari"
    /// Shorter drags are a slipped click, not a deliberate drag.
    static let minDistance: CGFloat = 40

    struct Node: Equatable {
        var role: String
        var url: URL?
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// The link dragged from: the nearest AXLink inside a web page, http(s) only.
    /// `chain` runs from the element under the point up through its parents.
    static func linkURL(_ chain: [Node]) -> URL? {
        guard chain.contains(where: { $0.role == "AXWebArea" }) else { return nil }
        for node in chain {
            if node.role == "AXWebArea" { return nil }
            if node.role == "AXLink" {
                guard let url = node.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return url
            }
        }
        return nil
    }

    /// Dropped on the page itself, not on browser chrome or a text field.
    static func isPageDrop(_ chain: [Node]) -> Bool {
        for node in chain {
            if node.role == "AXWebArea" { return true }
            if textRoles.contains(node.role) { return false }
        }
        return false
    }

    static func target(start: [Node], end: [Node]) -> URL? {
        isPageDrop(end) ? linkURL(start) : nil
    }

    /// A new tab at the end of the front window. `make new tab` leaves the current tab
    /// selected, so several links can be collected and read later; each lands after the last.
    static func openScript(_ url: URL) -> String {
        let quoted = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application id \"\(bundleID)\" to tell front window to "
            + "make new tab at end of tabs with properties {URL:\"\(quoted)\"}"
    }

    /// Element under `point` and its parents, nearest first.
    private static func chain(at point: CGPoint, limit: Int = 12) -> [Node] {
        let fx = Actions.shared.effects
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return [] }
        var nodes: [Node] = []
        for _ in 0..<limit {
            let role = fx.axCopy(element, kAXRoleAttribute as String) as? String ?? ""
            let url = role == "AXLink" ? fx.axCopy(element, kAXURLAttribute as String) as? URL : nil
            nodes.append(Node(role: role, url: url))
            guard role != "AXWebArea", let parent = fx.axCopy(element, kAXParentAttribute as String),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return nodes
    }

    /// Background queue, after the release.
    static func handle(start: CGPoint, end: CGPoint) {
        let from = chain(at: start), to = chain(at: end)
        guard let url = target(start: from, end: to) else {
            Log.write("link drag: not opened, start=\(from.prefix(3).map(\.role)) end=\(to.prefix(3).map(\.role))")
            return
        }
        Log.write("link drag: opening in a background tab")
        Actions.shared.effects.runAppleScript(openScript(url))
    }
}
