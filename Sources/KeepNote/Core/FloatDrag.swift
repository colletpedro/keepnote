import CoreGraphics
import Foundation

/// The geometry of dragging a note off the deck and back onto it. Screen
/// coordinates, y up, the deck on `edge`.
enum FloatDrag {
    /// An anchored note floats once the cursor has gone this far from where
    /// the drag began, away from the edge (towards the middle of the screen).
    static let floatDistance: CGFloat = 40
    /// A floating note whose side comes this close to the deck's edge of the
    /// screen (or past it) snaps back into the deck when let go.
    static let snapDistance: CGFloat = 24

    static func shouldFloat(start: CGPoint, current: CGPoint, edge: ScreenEdge = .right) -> Bool {
        (current.x - start.x) * edge.inward > floatDistance
    }

    /// `screen` is the visible frame of the screen the cursor is on.
    static func isInSnapZone(noteFrame: CGRect, screen: CGRect, edge: ScreenEdge = .right) -> Bool {
        switch edge {
        case .right: return noteFrame.maxX >= screen.maxX - snapDistance
        case .left: return noteFrame.minX <= screen.minX + snapDistance
        }
    }

    /// The frame that follows the cursor: moved by exactly what the cursor
    /// moved since the drag began, size unchanged.
    static func followed(_ startFrame: CGRect, from start: CGPoint, to current: CGPoint) -> CGRect {
        startFrame.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
    }

    /// The moment an anchored note floats it takes its floating size, and the
    /// cursor keeps hold of the same spot on it — the same fraction across and
    /// the same distance from the top, where the spine and header are.
    static func floated(from anchored: CGRect, size: CGSize, cursor: CGPoint) -> CGRect {
        let fraction = anchored.width > 0 ? (cursor.x - anchored.minX) / anchored.width : 0.5
        let clamped = min(max(fraction, 0), 1)
        let fromTop = min(max(anchored.maxY - cursor.y, 0), size.height)
        return CGRect(
            x: cursor.x - clamped * size.width,
            y: cursor.y + fromTop - size.height,
            width: size.width,
            height: size.height
        )
    }
}
