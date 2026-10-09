import AppKit

/// A small text box that appears beside a deck button while the cursor is on
/// it. AppKit's own tooltips do not show over the deck, which never activates
/// the app, so this is a panel of its own: it takes no clicks and no focus.
@MainActor
final class HoverLabel {
    private var panel: NSPanel?

    /// Shows `text` to the left of `anchor` (screen coordinates), centred on it,
    /// above `level`.
    func show(_ text: String, besides anchor: NSRect, above level: NSWindow.Level) {
        hide()
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11.5, weight: .medium)
        field.textColor = .white
        field.sizeToFit()
        let size = NSSize(width: ceil(field.frame.width) + 16, height: ceil(field.frame.height) + 8)

        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        box.layer?.cornerRadius = 7
        field.frame.origin = NSPoint(x: 8, y: 4)
        box.addSubview(field)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = box
        panel.setFrameOrigin(NSPoint(x: anchor.minX - size.width - 8, y: anchor.midY - size.height / 2))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isShowing: Bool { panel != nil }
    var textForTesting: String? { (panel?.contentView?.subviews.first as? NSTextField)?.stringValue }
}
