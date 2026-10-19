import CoreGraphics

/// Where a screen's deck goes, from the screen's visible frame.
///
/// The visible frame, not the whole screen: it leaves out the menu bar and
/// the Dock, on whichever side the Dock is — so on the left edge with the Dock
/// on the left, the deck sits just beside the Dock, as it does beside a Dock
/// on the right. When the Dock moves or hides, the visible frame changes and
/// the deck is placed again.
enum DeckPlacement {
    /// A margin above and below the deck.
    static let verticalMargin: CGFloat = 24

    /// The height `visible` leaves for the deck.
    static func usableHeight(in visible: CGRect) -> CGFloat {
        visible.height - verticalMargin
    }

    /// The resting stripe: on the edge, centred on the visible height.
    static func pillFrame(height: CGFloat, in visible: CGRect, edge: ScreenEdge) -> CGRect {
        CGRect(x: edge.flushX(width: EdgeMetrics.pillWidth, in: visible), y: visible.midY - height / 2,
               width: EdgeMetrics.pillWidth, height: height)
    }

    /// The open deck: as wide as a tab plus the room a hovered tab grows into,
    /// as tall as its geometry, never taller than the visible frame.
    static func deckFrame(deckHeight: CGFloat, in visible: CGRect, edge: ScreenEdge) -> CGRect {
        let width = EdgeMetrics.tabWidth + EdgeMetrics.hoverGutter
        let height = min(deckHeight, visible.height)
        return CGRect(x: edge.flushX(width: width, in: visible), y: visible.midY - height / 2, width: width, height: height)
    }
}
