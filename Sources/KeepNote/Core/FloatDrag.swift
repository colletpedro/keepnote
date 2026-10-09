import CoreGraphics
import Foundation

/// The geometry of dragging a note off the deck and back onto it. Screen
/// coordinates, y up, the deck on the right edge.
enum FloatDrag {
    /// An anchored note floats once the cursor has gone this far from where
    /// the drag began, away from the edge (to the left).
    static let floatDistance: CGFloat = 40
    /// A floating note whose right side comes this close to the screen's right
    /// edge (or past it) snaps back into the deck when let go.
    static let snapDistance: CGFloat = 24

    static func shouldFloat(start: CGPoint, current: CGPoint) -> Bool {
        start.x - current.x > floatDistance
    }

    static func isInSnapZone(noteFrame: CGRect, screenMaxX: CGFloat) -> Bool {
        noteFrame.maxX >= screenMaxX - snapDistance
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
