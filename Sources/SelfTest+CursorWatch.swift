import Cocoa

// 光标跳变诊断：只判定规则（不启动定时器）。
extension SelfTest {
    static func cursorWatchChecks() -> [SelfTestCheck] {
        func strokeEnds(_ end: CGPoint, chord: Bool = false) -> [CGPoint] {
            var c = Config.defaultConfig; c.gestureButton = chord ? nil : "right"
            let e = GestureEngine(config: c)
            e.rulesetOverride = "selftest.none"
            e.isButtonHeld = { _ in true }
            var ends: [CGPoint] = []
            e.onStrokeEnded = { ends.append($0) }
            let savedClick = GestureEngine.postRightClick
            GestureEngine.postRightClick = { _ in }
            defer { GestureEngine.postRightClick = savedClick }
            func ev(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton) -> CGEvent {
                CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
            }
            let start = CGPoint(x: 500, y: 500)
            if chord { _ = e.handle(type: .leftMouseDown, event: ev(.leftMouseDown, start, .left)) }
            _ = e.handle(type: .rightMouseDown, event: ev(.rightMouseDown, start, .right))
            _ = e.handle(type: .rightMouseDragged, event: ev(.rightMouseDragged, end, .right))
            _ = e.handle(type: .rightMouseUp, event: ev(.rightMouseUp, end, .right))
            if chord { _ = e.handle(type: .leftMouseUp, event: ev(.leftMouseUp, end, .left)) }
            return ends
        }
        let end = CGPoint(x: 300, y: 500)
        let centers = [CGPoint(x: 960, y: 540), CGPoint(x: 2880, y: 540)]
        func kind(_ a: CGPoint, _ b: CGPoint) -> CursorWatch.Jump? { CursorWatch.classify(from: a, to: b, centers: centers) }
        return [
            SelfTestCheck(name: "cursor resync: right-button stroke syncs to where it ended", ok: strokeEnds(end) == [end]),
            SelfTestCheck(name: "cursor resync: plain right click does not", ok: strokeEnds(CGPoint(x: 502, y: 500)).isEmpty),
            SelfTestCheck(name: "cursor resync: not while another button is still down", ok: strokeEnds(end, chord: true).isEmpty),
            SelfTestCheck(name: "cursorwatch: jump to a display centre", ok: kind(CGPoint(x: 100, y: 100), CGPoint(x: 2881, y: 539)) == .center),
            SelfTestCheck(name: "cursorwatch: slow move through the centre is normal", ok: kind(CGPoint(x: 950, y: 540), CGPoint(x: 960, y: 540)) == nil),
            SelfTestCheck(name: "cursorwatch: ordinary fast move is normal", ok: kind(CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 300)) == nil),
            SelfTestCheck(name: "cursorwatch: big move out of a still cursor",
                          ok: CursorWatch.classify(before: CGPoint(x: 100, y: 100), from: CGPoint(x: 101, y: 100), to: CGPoint(x: 400, y: 300), centers: centers) == .teleport),
            SelfTestCheck(name: "cursorwatch: same move while already moving is normal",
                          ok: CursorWatch.classify(before: CGPoint(x: 0, y: 0), from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300), centers: centers) == nil),
            SelfTestCheck(name: "cursorwatch: huge jump elsewhere", ok: kind(CGPoint(x: 0, y: 0), CGPoint(x: 2000, y: 100)) == .huge),
        ]
    }
}
