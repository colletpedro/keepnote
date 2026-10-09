import AppKit

/// The shared look of a note card, so a tab in the deck and an open note are
/// visibly the same object at two sizes.
///
/// A card is `[tab | perforation | body]`. Its right edge is square, because it
/// is always flush against the screen edge; the other three corners are
/// rounded.
enum NoteCardShape {
    static func path(in rect: NSRect, radius: CGFloat = EdgeMetrics.cardCornerRadius) -> NSBezierPath {
        // Overhang the right side so that edge stays square once the view
        // clips it, without hand-rolling the corner arcs.
        let extended = NSRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width + radius,
            height: rect.height
        )
        return NSBezierPath(roundedRect: extended, xRadius: radius, yRadius: radius)
    }

    /// The tear line between the tab and the body of the note.
    static func drawPerforation(at x: CGFloat, in rect: NSRect, color: NSColor) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: rect.minY + 10))
        line.line(to: NSPoint(x: x, y: rect.maxY - 10))
        line.lineWidth = 1
        line.setLineDash([2.5, 3.5], count: 2, phase: 0)
        color.setStroke()
        line.stroke()
    }

    /// The note's label, rotated to run up the tab: 10.5 pt semibold in the
    /// note's own case, no tracking. `slice` is how much of the tab shows,
    /// from its top; `TabLabel` decides whether the label fits there.
    static func drawTabLabel(
        _ text: String,
        in tabRect: NSRect,
        slice: CGFloat,
        markerZone: CGFloat,
        color: NSColor,
        context: CGContext
    ) {
        // A title longer than a whole tab ends in an ellipsis rather than a cut.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        var label = NSAttributedString(string: text, attributes: attributes)
        let size = label.size()
        guard let zone = TabLabel.zone(
            textLength: ceil(size.width), tabHeight: tabRect.height, slice: slice, markerZone: markerZone
        ) else { return }
        var width = zone.length
        // Too little room for letters and an ellipsis both: the first
        // letters that fit whole, with nothing after them.
        if width < ceil(size.width), width < 28 {
            var prefix = ""
            for character in text {
                let longer = NSAttributedString(string: prefix + String(character), attributes: attributes)
                guard longer.size().width <= width else { break }
                prefix.append(character)
            }
            guard !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            label = NSAttributedString(string: prefix, attributes: attributes)
            width = ceil(label.size().width)
        }
        let midY = tabRect.minY + (zone.minY + zone.maxY) / 2

        context.saveGState()
        // A quarter turn clockwise, so the label reads top-to-bottom down the
        // tab, then centred on the tab's long axis.
        context.translateBy(
            x: tabRect.midX - size.height / 2,
            y: midY + width / 2
        )
        context.rotate(by: -.pi / 2)
        label.draw(in: NSRect(x: 0, y: 0, width: width, height: size.height + 2))
        context.restoreGState()
    }

    /// Elevation for a card sitting in the deck.
    ///
    /// Two things here are deliberate and both exist to stop the deck looking
    /// like a row of cut-out PNGs:
    ///
    /// The shadow falls **sideways**, not down. Neighbouring tabs are only a
    /// few points apart, so a vertical shadow has nowhere to fade out: its
    /// gradient gets squeezed into a gap narrower than its own radius, and the
    /// shadows of adjacent cards pile up there into a hard dark bar. Throwing
    /// it left, into open space, gives it room.
    ///
    /// And the radius stays under the gap between cards, for the same reason.
    static func applyShadow(to view: NSView, strength: CGFloat = 1) {
        view.wantsLayer = true
        view.layer?.shadowColor = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.13, alpha: 1).cgColor
        view.layer?.shadowOpacity = Float(0.13 * strength)
        view.layer?.shadowRadius = 4
        view.layer?.shadowOffset = CGSize(width: -3, height: 0)
        updateShadowPath(on: view)
    }

    /// Pins the shadow to the card's actual silhouette.
    ///
    /// Without a path, Core Animation derives the shadow from the layer's alpha
    /// channel. For a view that draws a shape reaching past its own bounds —
    /// which this one does, to keep the right edge square — that derivation is
    /// what produces the crescent-shaped, clipped-looking smudge.
    static func updateShadowPath(on view: NSView) {
        guard let layer = view.layer else { return }
        let rect = view.bounds
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(EdgeMetrics.cardCornerRadius, min(rect.width, rect.height) / 2)
        layer.shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }
}
