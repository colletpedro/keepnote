import CoreGraphics

/// The side of the screen the deck lives on: Settings > Deck > Screen edge.
///
/// Everything the deck draws is laid out for the right edge and mirrored here
/// for the left one, so the two can never drift apart: a rect flush against
/// the edge, the side things slide in from, the direction "towards the middle
/// of the screen".
enum ScreenEdge: String, CaseIterable, Sendable {
    case right
    case left

    var title: String {
        switch self {
        case .right: return L("Right")
        case .left: return L("Left")
        }
    }

    /// Away from the edge, towards the middle of the screen: -1 on the right
    /// edge (leftwards), +1 on the left.
    var inward: CGFloat { self == .right ? -1 : 1 }

    /// The x of something `width` wide flush against this edge of `area`.
    func flushX(width: CGFloat, in area: CGRect) -> CGFloat {
        self == .right ? area.maxX - width : area.minX
    }

    /// `rect`, laid out for the right edge in a container `width` wide, moved
    /// to the same place measured from the left. Unchanged on the right edge.
    func mirrored(_ rect: CGRect, in width: CGFloat) -> CGRect {
        guard self == .left else { return rect }
        return CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// An x laid out for the right edge, for something `itemWidth` wide in a
    /// container `width` wide, mirrored.
    func mirroredX(_ x: CGFloat, itemWidth: CGFloat, in width: CGFloat) -> CGFloat {
        mirrored(CGRect(x: x, y: 0, width: itemWidth, height: 0), in: width).minX
    }

    /// Just past the edge, outside a container `width` wide: where a tab of
    /// `itemWidth` slides in from and folds back to.
    func offscreenX(itemWidth: CGFloat, in width: CGFloat) -> CGFloat {
        self == .right ? width : -itemWidth
    }
}
