import AppKit

/// The resting state: a thin stripe on the screen edge, one small coloured dash
/// per note. No window frame, no chrome, nothing to click — reaching it with
/// the cursor is the whole interaction.
final class PillView: NSView {
    var colors: [NoteColor] = [] {
        didSet { needsDisplay = true }
    }

    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    /// Height the stripe needs for the dashes it has to show.
    static func height(forNoteCount count: Int) -> CGFloat {
        let clamped = max(1, min(count, EdgeMetrics.pillDashLimit))
        let dashes = CGFloat(clamped) * EdgeMetrics.dashHeight
        let gaps = CGFloat(max(0, clamped - 1)) * EdgeMetrics.dashSpacing
        return dashes + gaps + EdgeMetrics.pillPadding * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let container = NoteCardShape.path(in: bounds, radius: EdgeMetrics.pillCornerRadius)

        // Barely there: enough to hold the dashes together over a busy
        // wallpaper, not enough to read as a window.
        let background = effectiveAppearance.isDark
            ? NSColor(white: 0.18, alpha: isHighlighted ? 0.55 : 0.28)
            : NSColor(white: 1.0, alpha: isHighlighted ? 0.60 : 0.32)
        background.setFill()
        container.fill()

        let dashX = (bounds.width - EdgeMetrics.dashWidth) / 2
        var y = bounds.height - EdgeMetrics.pillPadding - EdgeMetrics.dashHeight

        for color in colors.prefix(EdgeMetrics.pillDashLimit) {
            let dash = NSRect(
                x: dashX,
                y: y,
                width: EdgeMetrics.dashWidth,
                height: EdgeMetrics.dashHeight
            )
            let path = NSBezierPath(
                roundedRect: dash,
                xRadius: EdgeMetrics.dashWidth / 2,
                yRadius: EdgeMetrics.dashWidth / 2
            )
            color.spine.withAlphaComponent(isHighlighted ? 1.0 : 0.92).setFill()
            path.fill()
            y -= EdgeMetrics.dashHeight + EdgeMetrics.dashSpacing
        }
    }
}
