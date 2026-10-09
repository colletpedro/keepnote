import CoreGraphics
import Foundation

func runFloatDragTests() {
    func yes(_ v: Bool) -> String { v ? "yes" : "no" }
    let start = CGPoint(x: 1400, y: 500)

    expect("40 pt to the left is not yet enough", yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 1360, y: 500))), "no")
    expect("past 40 pt to the left floats", yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 1359, y: 500))), "yes")
    expect("vertical travel alone does not float", yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 1400, y: 300))), "no")
    expect("toward the edge does not float", yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 1480, y: 500))), "no")
    expect("diagonal counts its leftward part", yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 1355, y: 420))), "yes")

    let screenMaxX: CGFloat = 1440
    func snaps(_ maxX: CGFloat) -> String {
        yes(FloatDrag.isInSnapZone(noteFrame: CGRect(x: maxX - 400, y: 100, width: 400, height: 300), screenMaxX: screenMaxX))
    }
    expect("25 pt from the edge: no snap", snaps(1415), "no")
    expect("24 pt from the edge: snap", snaps(1416), "yes")
    expect("touching the edge: snap", snaps(1440), "yes")
    expect("past the edge: snap", snaps(1500), "yes")
    expect("far away: no snap", snaps(900), "no")

    let moved = FloatDrag.followed(CGRect(x: 100, y: 200, width: 300, height: 400), from: CGPoint(x: 150, y: 550), to: CGPoint(x: 90, y: 600))
    expect("follows the cursor", NSStringFromRect(moved), NSStringFromRect(NSRect(x: 40, y: 250, width: 300, height: 400)))

    // Anchored note 380 x 300 at the right edge, grabbed on the spine near
    // the top; it takes 468 x 440 and the grip stays on the spine.
    let anchored = CGRect(x: 1060, y: 300, width: 380, height: 300)
    let cursor = CGPoint(x: 1080, y: 580)
    let floated = FloatDrag.floated(from: anchored, size: CGSize(width: 468, height: 440), cursor: cursor)
    expect("floated: takes the floating size", "\(floated.width)x\(floated.height)", "468.0x440.0")
    expectTrue("floated: same fraction across", abs((cursor.x - floated.minX) / floated.width - 20.0 / 380) < 0.0001)
    expect("floated: same distance from the top", String(Double(floated.maxY - cursor.y)), "20.0")
    let outside = FloatDrag.floated(from: anchored, size: CGSize(width: 468, height: 440), cursor: CGPoint(x: 900, y: 700))
    expectTrue("floated: a cursor outside is clamped onto the note", outside.minX <= 900 && outside.maxX >= 900 && outside.maxY >= 700)
}
