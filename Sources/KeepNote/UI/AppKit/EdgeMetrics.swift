import CoreGraphics

/// Every number the deck is built from, in one place.
///
/// The model: a note is one card, `[tab | perforation | body]`. In the deck you
/// see only the tab, flush against the screen edge. Opening slides the whole
/// card left, clear of the deck, so the body can be read — the tab travels with
/// it and stays the note's handle.
enum EdgeMetrics {
    // MARK: Resting pill

    /// Width of the resting pill. The whole app is invisible except for this.
    static let pillWidth: CGFloat = 12
    /// One dash per note inside the pill.
    static let dashWidth: CGFloat = 5
    static let dashHeight: CGFloat = 15
    static let dashSpacing: CGFloat = 5
    static let pillPadding: CGFloat = 7
    static let pillCornerRadius: CGFloat = 7
    /// The stripe shows a dash for at most this many notes.
    static let pillDashLimit = 8

    // MARK: Deck

    /// How much of a card sticks out past the screen edge when the deck is fanned.
    static let tabWidth: CGFloat = 48
    /// Room to the left of the tabs so a hovered card can grow without being
    /// clipped, and so its shadow has somewhere to fall. It has to cover the
    /// lift plus the shadow's reach, or the highlight ends in a hard vertical
    /// cut — which is exactly what it is there to avoid.
    static let hoverGutter: CGFloat = 33
    /// How much further a hovered tab reaches out of the deck, at the setting
    /// the deck is made with (Settings > Deck > Hover magnification). It grows
    /// leftward with its right edge pinned: sliding it would peel it off the
    /// screen edge, which reads as the card being cut rather than picked up.
    static let hoverLift: CGFloat = 12
    /// What the shadow of a lifted tab needs past the lift itself.
    static let hoverShadowReach: CGFloat = 14
    /// The magnification slider: Off at 0, each step this many points more,
    /// Large at `hoverMagnificationLevels`. The deck's own 12 pt is level 2.
    static let hoverMagnificationStep: CGFloat = 6
    static let hoverMagnificationLevels = 6
    static let defaultHoverMagnification = 2

    /// How far a tab reaches at `level` of the slider.
    static func lift(forMagnification level: Int) -> CGFloat {
        CGFloat(min(max(level, 0), hoverMagnificationLevels)) * hoverMagnificationStep
    }

    /// How much further out of the edge the notes of an open group stand than
    /// the loose ones, so they stand out.
    static let groupOutset: CGFloat = 7
    /// The strip in the group's colour down the inner side of its notes.
    static let groupRailWidth: CGFloat = 5
    /// The group's colour button on its header, and its smallest target.
    static let groupColorButton: CGFloat = 24

    /// The room beside the tabs for a lift of `lift`, the outset of a group's
    /// notes and the shadow. At the deck's own 12 pt it is `hoverGutter`.
    static func gutter(forLift lift: CGFloat) -> CGFloat {
        lift + hoverShadowReach + groupOutset
    }
    /// Every tab is this tall, however many there are: a deck that does not
    /// fit stacks its tabs more tightly, it never shrinks them.
    static let tabHeight: CGFloat = 104
    /// The most an open group's header grows to show its name whole; a longer name ends in an ellipsis.
    static let openHeaderMaxHeight: CGFloat = 180
    static let tabSpacing: CGFloat = 6
    /// When the tabs do not fit, each one covers the one above it, leaving
    /// at least this much of it showing. Past that the deck scrolls.
    static let minimumVisibleSlice: CGFloat = 22
    static let cardCornerRadius: CGFloat = 12

    /// The round "+" under the deck.
    static let plusDiameter: CGFloat = 28
    static let plusTopMargin: CGFloat = 12
    /// Between the "+" and the round Today's Daily button beside it.
    static let dailyButtonGap: CGFloat = 8

    /// The "+N" chip, counting the tabs scrolled out of sight once a screen
    /// cannot hold them all (`DeckGeometry.capacity`, per screen).
    static let overflowHeight: CGFloat = 26

    // MARK: Hover preview

    /// The peek that hovering a tab opens.
    ///
    /// Measured off the reference shot — 244 × 199 pt on a 1280 × 832 pt
    /// display — then taken a little shallower still, which reads more like a
    /// card and less like a window. Small enough that clicking visibly develops
    /// it into the editor rather than swapping one card for another the same
    /// size.
    static let previewSize = CGSize(width: 244, height: 170)
    /// How far the preview's right end stays under the deck.
    static let previewTuck: CGFloat = 30
    /// The peek opens the moment the cursor lands on a tab — no wait. Sweeping
    /// across the deck does not flash a card per tab because a peek already on
    /// screen slides to the next tab instead of being dismissed and rebuilt.
    ///
    /// Closing does wait, so the gap between a tab and its peek does not count
    /// as leaving.
    static let previewGrace: Double = 0.14

    // MARK: Note card

    /// Anchored: the note as it sits beside the deck, tab still attached.
    static let anchoredSize = CGSize(width: 380, height: 300)
    /// Floating: the note lifted off the edge, its spine kept, full controls.
    /// 420 pt of paper plus the 48 pt spine.
    static let detachedSize = CGSize(width: 420 + tabWidth, height: 440)
    static let minimumNoteSize = CGSize(width: 360, height: 240)

    // MARK: Timing

    /// Grace period after the cursor leaves before the deck collapses, so
    /// crossing a gap between tabs does not slam it shut.
    static let collapseGrace: Double = 0.32
}
