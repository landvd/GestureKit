import Cocoa

// Safari 拖链接新开标签：判定规则与引擎的触发条件（不碰真实 AX / Safari）。
extension SelfTest {
    static func linkDragChecks() -> [SelfTestCheck] {
        var out: [SelfTestCheck] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append(SelfTestCheck(name: name, ok: ok, detail: detail))
        }
        typealias N = LinkDrag.Node
        let url = URL(string: "https://example.com/a")!
        let page = N(role: "AXWebArea", url: nil)
        let link = [N(role: "AXStaticText", url: nil), N(role: "AXLink", url: url), N(role: "AXGroup", url: nil), page]
        let blank = [N(role: "AXGroup", url: nil), page]

        check("linkdrag: link text inside a page → its URL", LinkDrag.linkURL(link) == url)
        check("linkdrag: no link → nothing", LinkDrag.linkURL(blank) == nil)
        check("linkdrag: AXLink outside a page (bookmarks bar) → nothing",
              LinkDrag.linkURL([N(role: "AXLink", url: url), N(role: "AXToolbar", url: nil)]) == nil)
        check("linkdrag: javascript: / missing URL → nothing",
              LinkDrag.linkURL([N(role: "AXLink", url: URL(string: "javascript:void(0)")), page]) == nil
                && LinkDrag.linkURL([N(role: "AXLink", url: nil), page]) == nil)
        check("linkdrag: drop on page opens", LinkDrag.target(start: link, end: blank) == url)
        check("linkdrag: drop on text field / browser chrome / nothing stays Safari's",
              LinkDrag.target(start: link, end: [N(role: "AXTextField", url: nil), page]) == nil
                && LinkDrag.target(start: link, end: [N(role: "AXTabGroup", url: nil)]) == nil
                && LinkDrag.target(start: link, end: []) == nil)
        check("linkdrag: opens a background tab in Safari, not the default browser",
              LinkDrag.openScript(url) == "tell application id \"com.apple.Safari\" to tell front window to "
                + "make new tab at end of tabs with properties {URL:\"https://example.com/a\"}",
              LinkDrag.openScript(url))
        let odd = LinkDrag.openScript(URL(string: "https://example.com/?q=%22x%22")!)
        check("linkdrag: script keeps the URL inside its string", odd.hasSuffix("{URL:\"https://example.com/?q=%22x%22\"}"), odd)

        func ev(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, flags: CGEventFlags = []) -> CGEvent {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
            e.flags = flags
            return e
        }
        /// (swallowed anything, handler calls)
        func drag(app: String = LinkDrag.bundleID, to: CGPoint = CGPoint(x: 200, y: 100), enabled: Bool? = nil,
                  flags: CGEventFlags = [], chord: Bool = false) -> (Bool, Int) {
            var c = Config.defaultConfig; c.dragLinkToNewTab = enabled
            let e = GestureEngine(config: c)
            e.rulesetOverride = app
            e.isButtonHeld = { _ in true }
            var calls = 0
            e.onLinkDrag = { _, _ in calls += 1 }
            let start = CGPoint(x: 100, y: 100)
            var swallowed = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, start, flags: flags)) == nil
            if chord {
                _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, start, .right))
                _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, start, .right))
            } else if e.handle(type: .leftMouseDragged, event: ev(.leftMouseDragged, to)) == nil {
                swallowed = true
            }
            if e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, to)) == nil { swallowed = true }
            return (swallowed, calls)
        }
        let plain = drag()
        check("linkdrag: Safari drag fires once and swallows nothing", plain.1 == 1 && !plain.0, "\(plain)")
        check("linkdrag: click / tiny drag ignored", drag(to: CGPoint(x: 110, y: 100)).1 == 0)
        check("linkdrag: other apps ignored", drag(app: "com.apple.finder").1 == 0)
        check("linkdrag: switched off ignored", drag(enabled: false).1 == 0)
        check("linkdrag: modifier held ignored", drag(flags: .maskCommand).1 == 0)
        check("linkdrag: chord cancels it", drag(chord: true).1 == 0)
        return out
    }
}
