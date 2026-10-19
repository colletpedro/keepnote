import CoreGraphics
import Foundation

/// The deck on both edges: the left one is the right one mirrored, to the
/// point — same heights, slices, fades and counts, every tab flush with its
/// edge, a hovered tab growing towards the middle of the screen.
func runScreenEdgeTests() {
    func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    func r(_ rect: CGRect) -> String { "\(f(rect.minX)) \(f(rect.minY)) \(f(rect.width)) \(f(rect.height))" }

    // ScreenEdge itself.
    let area = CGRect(x: 72, y: 0, width: 1440, height: 900)
    expect("edge: flush right", f(ScreenEdge.right.flushX(width: 74, in: area)), "1438.00")
    expect("edge: flush left", f(ScreenEdge.left.flushX(width: 74, in: area)), "72.00")
    expect("edge: towards the middle", "\(ScreenEdge.right.inward) \(ScreenEdge.left.inward)", "-1.0 1.0")
    expect("edge: mirrored", r(ScreenEdge.left.mirrored(CGRect(x: 26, y: 5, width: 48, height: 104), in: 74)),
           r(CGRect(x: 0, y: 5, width: 48, height: 104)))
    expect("edge: right is left as it is", r(ScreenEdge.right.mirrored(CGRect(x: 26, y: 5, width: 48, height: 104), in: 74)),
           r(CGRect(x: 26, y: 5, width: 48, height: 104)))
    expect("edge: slides in from past the right side", f(ScreenEdge.right.offscreenX(itemWidth: 60, in: 74)), "74.00")
    expect("edge: and past the left side", f(ScreenEdge.left.offscreenX(itemWidth: 60, in: 74)), "-60.00")

    // DeckGeometry, every mode, hovered or not, pinned or not.
    let width: CGFloat = EdgeMetrics.tabWidth + EdgeMetrics.hoverGutter
    let cases: [(String, Int, DeckGeometry.Hover?, DeckGeometry.PinnedBlock?)] = [
        ("spaced", 6, nil, nil),
        ("packed", 20, nil, nil),
        ("scrolling", 60, nil, nil),
        ("packed, hovered", 20, DeckGeometry.Hover(index: 7, cursorY: 500), nil),
        ("scrolling, hovered", 60, DeckGeometry.Hover(index: 3, cursorY: 820), nil),
        ("pinned", 30, nil, DeckGeometry.PinnedBlock(above: 10, count: 3)),
        ("pinned, a pinned tab hovered", 30, DeckGeometry.Hover(index: 11, cursorY: 0), DeckGeometry.PinnedBlock(above: 10, count: 3)),
    ]
    for (name, count, hover, pinned) in cases {
        let right = DeckGeometry.layout(count: count, usableHeight: 926, columnWidth: width, pinned: pinned, hover: hover, edge: .right)
        let left = DeckGeometry.layout(count: count, usableHeight: 926, columnWidth: width, pinned: pinned, hover: hover, edge: .left)
        expectTrue("geometry (\(name)): left is right mirrored",
                   zip(left.frames, right.frames).allSatisfy { $0.minX == width - $1.maxX && $0.minY == $1.minY && $0.size == $1.size })
        expectTrue("geometry (\(name)): the same heights, slices and fades",
                   left.slices == right.slices && left.alphas == right.alphas && left.columnHeight == right.columnHeight
                   && left.deckHeight == right.deckHeight && left.hiddenCount == right.hiddenCount && left.hovered == right.hovered)
        expectTrue("geometry (\(name)): right tabs flush with the right side", right.frames.allSatisfy { $0.maxX == width })
        expectTrue("geometry (\(name)): left tabs flush with the left side", left.frames.allSatisfy { $0.minX == 0 })
        if let hovered = left.hovered {
            expect("geometry (\(name)): the hovered tab grows towards the middle, on the left",
                   f(left.frames[hovered].maxX), f(EdgeMetrics.tabWidth + EdgeMetrics.hoverLift))
            expect("geometry (\(name)): and on the right",
                   f(right.frames[hovered].minX), f(width - EdgeMetrics.tabWidth - EdgeMetrics.hoverLift))
        }
    }
    // Hit-testing on the left: the tab is by the edge, the gutter on the inside.
    let left = DeckGeometry.layout(count: 6, usableHeight: 926, columnWidth: width, edge: .left)
    let midY = left.frames[2].midY
    expect("geometry: on the left a point by the edge is on the tab", left.tab(at: CGPoint(x: 6, y: midY)).map(String.init), "2")
    expectTrue("geometry: and the gutter is not", left.tab(at: CGPoint(x: width - 4, y: midY)) == nil)

    // DeckIntent: on the left edge the cursor arrives from the right and a
    // crossing goes off to the left, onto the display beside.
    var dwell = DeckIntent(delay: 0.150)
    dwell.enter(at: CGPoint(x: 6, y: 400), time: 10)
    expect("intent (left): waits for the delay", "\(dwell.decision(now: 10.1))", "\(DeckIntent.Decision.wait(until: 10.15))")
    expect("intent (left): opens after it", "\(dwell.decision(now: 10.15))", "\(DeckIntent.Decision.open)")
    var crossing = DeckIntent(delay: 0.150)
    crossing.enter(at: CGPoint(x: 10, y: 400), time: 20)
    crossing.move(to: CGPoint(x: 1, y: 400), time: 20.008)   // 1125 pt/s, leftwards
    expectTrue("intent (left): a fast crossing to the left display does not open", crossing.decision(now: 20.008) != .open)
    var slow = DeckIntent(delay: 0.150)
    slow.enter(at: CGPoint(x: 10, y: 400), time: 30)
    slow.move(to: CGPoint(x: 8, y: 400), time: 30.016)
    expect("intent (left): a slow arrival opens at once", "\(slow.decision(now: 30.016))", "\(DeckIntent.Decision.open)")
    var rightCrossing = DeckIntent(delay: 0.150)
    rightCrossing.enter(at: CGPoint(x: 1434, y: 400), time: 40)
    rightCrossing.move(to: CGPoint(x: 1443, y: 400), time: 40.008)
    expectTrue("intent (right): a fast crossing to the right display does not open", rightCrossing.decision(now: 40.008) != .open)

    // Floating and snapping back, on the left.
    func yes(_ v: Bool) -> String { v ? "yes" : "no" }
    let start = CGPoint(x: 100, y: 500)
    expect("drag (left): 40 pt to the right is not yet enough",
           yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 140, y: 500), edge: .left)), "no")
    expect("drag (left): past 40 pt to the right floats",
           yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 141, y: 500), edge: .left)), "yes")
    expect("drag (left): towards the edge does not float",
           yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 20, y: 500), edge: .left)), "no")
    expect("drag (right): to the right does not float",
           yes(FloatDrag.shouldFloat(start: start, current: CGPoint(x: 200, y: 500), edge: .right)), "no")
    func snapsLeft(_ minX: CGFloat, screen: CGRect = CGRect(x: 0, y: 0, width: 1440, height: 900)) -> String {
        yes(FloatDrag.isInSnapZone(noteFrame: CGRect(x: minX, y: 100, width: 400, height: 300), screen: screen, edge: .left))
    }
    expect("snap (left): 25 pt from the edge: no", snapsLeft(25), "no")
    expect("snap (left): 24 pt: yes", snapsLeft(24), "yes")
    expect("snap (left): past the edge: yes", snapsLeft(-60), "yes")
    expect("snap (left): by the right edge: no", snapsLeft(1040), "no")
    expect("snap (left): measured from a left Dock", snapsLeft(96, screen: CGRect(x: 72, y: 0, width: 1440, height: 900)), "yes")
    expect("snap (right): the left edge does not snap on the right",
           yes(FloatDrag.isInSnapZone(noteFrame: CGRect(x: 0, y: 100, width: 400, height: 300),
                                      screen: CGRect(x: 0, y: 0, width: 1440, height: 900), edge: .right)), "no")
}
