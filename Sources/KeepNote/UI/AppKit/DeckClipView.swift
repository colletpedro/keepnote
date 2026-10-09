import AppKit

/// The window the deck scrolls behind.
///
/// Tabs are laid out in one tall column and this view shows a slice of it, so
/// scrolling is a continuous change of offset rather than a rebuild. Cards that
/// run past the top or bottom are clipped here and faded by the layout pass, so
/// they slide out of sight instead of blinking away.
final class DeckClipView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    /// The clip view is only a viewport; every event belongs to the deck.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
