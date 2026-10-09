import CoreGraphics

/// Where a tab's rotated label goes, or whether it goes at all.
///
/// A whole tab shows its label as it always has: centred along the tab, an
/// ellipsis if it is longer than the tab. A tab partly covered by the one
/// below shows only its top `slice`, and the label stays inside it: whole when
/// it fits, otherwise as much of its start as fits, ending in an ellipsis —
/// never running under the next tab. Only a slice too thin for even that
/// shows no label.
enum TabLabel {
    /// Clear space at each end of the label on a whole tab.
    static let padding: CGFloat = 10
    /// Tighter in a slice, where every point is a letter more.
    static let slicePadding: CGFloat = 4
    /// The least worth drawing in a slice: a letter or two and the ellipsis.
    static let minimumLength: CGFloat = 14

    struct Zone: Equatable {
        /// The stretch of the tab the label is centred in, measured up from
        /// the tab's bottom edge.
        var minY: CGFloat
        var maxY: CGFloat
        /// How much of the label to draw; when less than its length, the rest
        /// becomes an ellipsis.
        var length: CGFloat
    }

    /// `markerZone` is what the floating-note marker takes at the top.
    static func zone(textLength: CGFloat, tabHeight: CGFloat, slice: CGFloat, markerZone: CGFloat = 0) -> Zone? {
        guard textLength > 0 else { return nil }
        let top = tabHeight - markerZone
        if slice >= tabHeight {
            let room = max(0, top - 2 * padding)
            return Zone(minY: 0, maxY: top, length: min(textLength, room))
        }
        let bottom = tabHeight - max(0, slice)
        let room = top - bottom - 2 * slicePadding
        guard room >= min(textLength, minimumLength) else { return nil }
        return Zone(minY: bottom, maxY: top, length: min(textLength, room))
    }
}
