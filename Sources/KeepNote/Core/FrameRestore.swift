import CoreGraphics
import Foundation

/// Saving and restoring where a lifted-off note sits. Pure geometry, so the
/// awkward cases — a monitor that is gone, a window larger than the screen —
/// can be tested.
enum FrameRestore {
    static func encode(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height].map { String(format: "%.1f", $0) }.joined(separator: " ")
    }

    static func decode(_ text: String) -> CGRect? {
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// Puts `saved` on the screen it overlaps most — or the first screen if it
    /// overlaps none, which is what a disconnected monitor looks like — with the
    /// size kept between `minimum` and the screen's own, and the whole frame
    /// inside it. `screens` are visible frames (menu bar and Dock excluded).
    static func fit(_ saved: CGRect, screens: [CGRect], minimum: CGSize) -> CGRect {
        guard let first = screens.first else { return saved }
        let area = screens.max { overlap($0, saved) < overlap($1, saved) }.flatMap {
            overlap($0, saved) > 0 ? $0 : nil
        } ?? first

        let width = min(max(saved.width, min(minimum.width, area.width)), area.width)
        let height = min(max(saved.height, min(minimum.height, area.height)), area.height)
        let x = min(max(saved.minX, area.minX), area.maxX - width)
        let y = min(max(saved.minY, area.minY), area.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}
