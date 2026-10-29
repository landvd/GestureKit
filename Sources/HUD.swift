import Cocoa

/// Small text bubble next to the cursor when an action fires
/// (docs/modules/12-hud.md, docs/RE_MODULES.md §10: 260pt max text width).
/// One panel is reused: a new message replaces the text and restarts the timer.
final class HUD {

    static let shared = HUD()

    static let maxTextWidth: CGFloat = 260
    private static let padding = NSSize(width: 12, height: 7)
    private static let cursorOffset: CGFloat = 16

    private var panel: NSPanel?
    private var label: NSTextField!
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    /// Show `text` near the cursor for `duration` seconds, then fade out.
    func show(_ text: String, duration: TimeInterval = 0.5) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text

        let fit = label.sizeThatFits(NSSize(width: HUD.maxTextWidth, height: .greatestFiniteMagnitude))
        let textSize = NSSize(width: min(ceil(fit.width), HUD.maxTextWidth), height: ceil(fit.height))
        let size = NSSize(width: textSize.width + HUD.padding.width * 2,
                          height: textSize.height + HUD.padding.height * 2)
        label.frame = NSRect(x: HUD.padding.width, y: HUD.padding.height,
                             width: textSize.width, height: textSize.height)

        let mouse = NSEvent.mouseLocation                     // Cocoa coords (bottom-left)
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let origin = HUD.origin(for: size, cursor: mouse, in: screen?.visibleFrame ?? .zero)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        hideWork?.cancel()
        generation += 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, duration), execute: work)
    }

    /// Bottom-right of the cursor; flips left/up when it would leave the screen.
    static func origin(for size: NSSize, cursor: NSPoint, in visible: NSRect) -> NSPoint {
        var x = cursor.x + cursorOffset
        var y = cursor.y - cursorOffset - size.height
        if visible.width > 0 {
            if x + size.width > visible.maxX { x = cursor.x - cursorOffset - size.width }
            if y < visible.minY { y = cursor.y + cursorOffset }
            x = max(visible.minX, min(x, visible.maxX - size.width))
            y = max(visible.minY, min(y, visible.maxY - size.height))
        }
        return NSPoint(x: x, y: y)
    }

    private func fadeOut() {
        guard let panel else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A newer message may have arrived during the fade.
            guard let self, self.generation == gen else { return }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]
        p.contentView = bg

        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .labelColor
        l.alignment = .center
        l.maximumNumberOfLines = 3
        l.lineBreakMode = .byTruncatingTail
        l.preferredMaxLayoutWidth = HUD.maxTextWidth
        bg.addSubview(l)

        label = l
        panel = p
        return p
    }
}
