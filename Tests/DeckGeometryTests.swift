import CoreGraphics
import Foundation

func runDeckGeometryTests() {
    // A screen that leaves 1000 pt for the deck: 960 for the column once the
    // "+" (40) is under it, 928 when the "+N" chip (32) is there too.
    func deck(_ count: Int, scroll: CGFloat = 0, height: CGFloat = 1000) -> DeckGeometry {
        DeckGeometry.layout(count: count, usableHeight: height, columnWidth: 74, scrollOffset: scroll)
    }
    func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    let full = EdgeMetrics.tabHeight

    // a. All of them fit: full height, the usual spacing, the deck as tall as they are.
    let eight = deck(8)
    expectTrue("spaced: eight fit", eight.mode == .spaced)
    expect("spaced: step is a tab and a gap", f(eight.step), f(full + EdgeMetrics.tabSpacing))
    expect("spaced: column is what they need", f(eight.columnHeight), f(8 * full + 7 * EdgeMetrics.tabSpacing))
    expectTrue("spaced: every tab whole", eight.slices.allSatisfy { $0 == full })
    expectTrue("spaced: every tab full height", eight.frames.allSatisfy { $0.height == full })
    expect("spaced: first tab at the top", f(eight.frames[0].maxY), f(eight.columnHeight))
    expect("spaced: last tab at the bottom", f(eight.frames[7].minY), "0.00")
    expect("spaced: flush with the column's right edge", f(eight.frames[0].maxX), "74.00")
    expectTrue("spaced: no overflow", !eight.showsOverflow && eight.hiddenCount == 0)
    expect("one tab", f(deck(1).columnHeight), f(full))
    expect("no tabs", String(deck(0).frames.count), "0")

    // b. They no longer fit: the step shrinks just enough, gaps first, then overlap.
    let nine = deck(9)
    expectTrue("packed: nine do not fit spaced", nine.mode == .packed)
    expect("packed: the step that fits them exactly", f(nine.step), f((960 - full) / 8))
    expectTrue("packed: gaps shrink before anything overlaps", nine.step >= full && nine.slices.allSatisfy { $0 == full })
    let twelve = deck(12)
    expect("packed: step for twelve", f(twelve.step), f((960 - full) / 11))
    expectTrue("packed: tabs overlap", twelve.step < full)
    expect("packed: an upper tab shows down to the next one", f(twelve.slices[3]), f(twelve.step))
    expect("packed: the last tab is whole", f(twelve.slices[11]), f(full))
    expect("packed: the deck takes the whole height", f(twelve.columnHeight), "960.00")
    expect("packed: first tab at the top", f(twelve.frames[0].maxY), "960.00")
    expect("packed: last tab at the bottom", f(twelve.frames[11].minY), "0.00")
    expectTrue("packed: tabs keep their full height", twelve.frames.allSatisfy { $0.height == full })
    expectTrue("packed: no overflow", !twelve.showsOverflow && twelve.hiddenCount == 0)

    var previous = CGFloat.infinity
    var continuous = true
    for count in 2...39 {
        let layout = deck(count)
        if layout.step > previous + 0.001 || previous.isFinite && previous - layout.step > 25 { continuous = false }
        previous = layout.step
    }
    expectTrue("packed: the step only ever shrinks, a little per note", continuous)
    expect("packed: thirty-nine still fit", f(deck(39).step), f((960 - full) / 38))
    expect("capacity: what the screen holds", String(DeckGeometry.capacity(usableHeight: 1000)), "39")
    expect("capacity: a shorter screen holds fewer", String(DeckGeometry.capacity(usableHeight: 700)), "26")

    // c. Past the limit: the minimum slice, scrolling, and the "+N" chip.
    let sixty = deck(60)
    expectTrue("scrolling: sixty", sixty.mode == .scrolling && sixty.showsOverflow)
    expect("scrolling: step stays at the minimum", f(sixty.step), f(EdgeMetrics.minimumVisibleSlice))
    expect("scrolling: the chip takes its room", f(sixty.columnHeight), "928.00")
    expect("scrolling: how far it scrolls", f(sixty.maxScrollOffset), f(59 * EdgeMetrics.minimumVisibleSlice + full - 928))
    expectTrue("scrolling: something is out of sight", sixty.hiddenCount > 0)
    let end = deck(60, scroll: 10_000)
    expect("scrolling: clamped at the end", f(end.scrollOffset), f(end.maxScrollOffset))
    expect("scrolling: the last tab sits on the bottom at the end", f(end.frames[59].minY), "0.00")
    expectTrue("scrolling: at the end the top is what is hidden", end.alphas[0] == 0 && end.alphas[59] == 1)
    expect("scrolling: never negative", f(deck(60, scroll: -40).scrollOffset), "0.00")
    expectTrue("scrolling: forty is past the limit", deck(40).mode == .scrolling)

    var fits = true
    for count in 0...80 {
        for height in [500, 700, 900, 1000, 1400] as [CGFloat] where deck(count, height: height).deckHeight > height + 0.001 {
            fits = false
        }
    }
    expectTrue("the deck never runs past the screen", fits)

    runDeckHoverTests()
    runPinnedDeckTests()
}

func runDeckHoverTests() {
    func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    let full = EdgeMetrics.tabHeight
    let lift = EdgeMetrics.hoverLift
    func deck(_ count: Int, scroll: CGFloat = 0, hover: DeckGeometry.Hover? = nil) -> DeckGeometry {
        DeckGeometry.layout(count: count, usableHeight: 1000, columnWidth: 74, scrollOffset: scroll, hover: hover)
    }

    // Spaced: the tab under the cursor reaches out, nothing else moves.
    let spaced = deck(8)
    let spacedHover = deck(8, hover: .init(cursorY: spaced.frames[3].midY))
    expect("spaced hover: the tab under the cursor", spacedHover.hovered.map(String.init), "3")
    expect("spaced hover: reaches 12 pt further", f(spacedHover.frames[3].minX), f(74 - EdgeMetrics.tabWidth - lift))
    expect("spaced hover: right edge stays on the screen edge", f(spacedHover.frames[3].maxX), "74.00")
    expectTrue("spaced hover: the others stay", (0..<8).filter { $0 != 3 }.allSatisfy { spacedHover.frames[$0] == spaced.frames[$0] })
    expect("spaced hover: the cursor in a gap is over nothing",
           deck(8, hover: .init(cursorY: spaced.frames[3].minY - 3)).hovered.map(String.init), nil)

    // Overlapping: every tab in turn, the cursor in the middle of its slice.
    let resting = deck(24)
    var whole = true, anchored = true, ends = true, sticky = true, onScreen = true, neighbours = true, total = true
    for open in 0..<24 {
        let topEdge = resting.frames[open].maxY
        let cursorY = topEdge - resting.slices[open] / 2
        let layout = deck(24, hover: .init(cursorY: cursorY))
        if layout.hovered != open { sticky = false; continue }
        if layout.slices[open] < full - 0.01 { whole = false }
        if !(layout.frames[open].minY...layout.frames[open].maxY).contains(cursorY) { anchored = false }
        if abs(layout.frames[0].maxY - layout.columnHeight) > 0.01 || abs(layout.frames[23].minY) > 0.01 { ends = false }
        if layout.tab(at: CGPoint(x: 60, y: cursorY)) != open { sticky = false }
        if layout.frames.contains(where: { $0.minY < -0.01 || $0.maxY > layout.columnHeight + 0.01 }) { onScreen = false }
        if layout.slices.dropLast().contains(where: { $0 < 6 - 0.01 }) { onScreen = false }
        if abs(layout.slices.dropLast().reduce(0, +) - resting.slices.dropLast().reduce(0, +)) > 0.01 { total = false }
        // Two tabs from either end, the short side has no room for the
        // second neighbour to open without the open tab leaving the cursor.
        for distance in (3...19).contains(open) ? [1, 2] : [1] {
            for index in [open - distance, open + distance] where index >= 0 && index < 23 && index != open {
                let far = (0..<23).filter { abs($0 - open) > 2 }
                if let other = far.first, layout.slices[index] <= layout.slices[other] { neighbours = false }
            }
        }
    }
    expectTrue("overlap hover: the open tab is whole", whole)
    expectTrue("overlap hover: it stays under the cursor", anchored)
    expectTrue("overlap hover: the cursor still finds it there", sticky)
    expectTrue("overlap hover: first and last tabs keep their places", ends)
    expectTrue("overlap hover: no tab leaves the deck or vanishes", onScreen)
    expectTrue("overlap hover: the others make exactly the room", total)
    expectTrue("overlap hover: neighbours open more than the rest", neighbours)

    let middle = deck(24, hover: .init(cursorY: resting.frames[12].maxY - 5))
    expectTrue("overlap hover: the nearer neighbour opens further",
               middle.slices[11] > middle.slices[10] && middle.slices[13] > middle.slices[14])
    expectTrue("overlap hover: neighbours open partly, not whole",
               middle.slices[11] < full && middle.slices[13] < full && middle.slices[11] > resting.step)
    expect("overlap hover: and reaches out 12 pt", f(middle.frames[12].width), f(EdgeMetrics.tabWidth + lift))

    // Moving onto the neighbour below keeps the cursor on the tab it reached.
    let point = CGPoint(x: 60, y: middle.frames[13].maxY - middle.slices[13] / 2)
    let next = middle.tab(at: point)
    expect("overlap hover: the neighbour is found where it is drawn", next.map(String.init), "13")
    let moved = deck(24, hover: .init(index: next, cursorY: point.y))
    expectTrue("overlap hover: the newly open tab opens under the cursor",
               moved.hovered == 13 && (moved.frames[13].minY...moved.frames[13].maxY).contains(point.y)
               && moved.tab(at: point) == 13)

    // Scrolling decks open the same way, inside their content.
    let sixty = deck(60, scroll: 200)
    let cursorY = sixty.frames[30].maxY - 4
    let scrolled = deck(60, scroll: 200, hover: .init(cursorY: cursorY))
    expectTrue("scrolling hover: open and whole under the cursor", scrolled.hovered == 30
               && scrolled.slices[30] >= full - 0.01 && (scrolled.frames[30].minY...scrolled.frames[30].maxY).contains(cursorY))
    expect("scrolling hover: the content keeps its length",
           f(scrolled.frames[59].minY - scrolled.frames[0].maxY), f(sixty.frames[59].minY - sixty.frames[0].maxY))
    expectTrue("no hover is the resting deck", deck(24, hover: nil) == resting)

    // The cursor moving down or up the deck, `step` points per event, the
    // deck recomputed only when the tab drawn under it changes — as
    // EdgeStackView does. Returns the tabs that were opened.
    func sweep(_ count: Int, height: CGFloat, from start: CGFloat, to end: CGFloat, step: CGFloat,
               layout initial: DeckGeometry? = nil) -> (opened: Set<Int>, layout: DeckGeometry) {
        func make(_ hover: DeckGeometry.Hover?) -> DeckGeometry {
            DeckGeometry.layout(count: count, usableHeight: height, columnWidth: 74, hover: hover)
        }
        var layout = initial ?? make(nil)
        var opened = Set<Int>()
        var y = start
        while start < end ? y <= end : y >= end {
            if let index = layout.tab(at: CGPoint(x: 60, y: y)) {
                if index != layout.hovered { layout = make(.init(index: index, cursorY: y)) }
                if let open = layout.hovered { opened.insert(open) }
            }
            y += start < end ? step : -step
        }
        return (opened, layout)
    }
    func inView(_ layout: DeckGeometry) -> Set<Int> {
        Set(layout.frames.indices.filter {
            let middle = layout.frames[$0].maxY - layout.slices[$0] / 2
            return middle > 0 && middle < layout.columnHeight
        })
    }

    var reached = true
    var failures: [String] = []
    for height in [700, 926, 1300] as [CGFloat] {
        for count in [9, 12, 20, 36, 60, 120] {
            let rest = DeckGeometry.layout(count: count, usableHeight: height, columnWidth: 74)
            let top = rest.columnHeight - 1
            let down = sweep(count, height: height, from: top, to: 1, step: 3).opened
            let up = sweep(count, height: height, from: 1, to: top, step: 3).opened
            if !inView(rest).isSubset(of: down) || !inView(rest).isSubset(of: up) {
                reached = false
                failures.append("\(count)@\(Int(height))")
            }
        }
    }
    expectTrue("sweep: moving slowly down or up opens every tab in view \(failures)", reached)

    var recovered = true
    for count in [20, 36, 60] {
        let rest = DeckGeometry.layout(count: count, usableHeight: 926, columnWidth: 74)
        // A fast flick down the deck skips tabs, as it should, and must not
        // leave the deck pushed out of shape: coming back up slowly reaches
        // every one of them.
        let flick = sweep(count, height: 926, from: rest.columnHeight - 1, to: 1, step: 24)
        let back = sweep(count, height: 926, from: 1, to: rest.columnHeight - 1, step: 3, layout: flick.layout)
        if !inView(rest).isSubset(of: back.opened) { recovered = false }
    }
    expectTrue("sweep: after a fast flick, every tab is still within reach", recovered)

    // With a tab open, any point of a neighbour's drawn slice — reached from
    // the side, from the peek, at any depth — opens that neighbour.
    var anywhere = true
    for count in [24, 36] {
        let rest = DeckGeometry.layout(count: count, usableHeight: 926, columnWidth: 74)
        for open in [1, 5, count / 2, count - 4] {
            let opened = DeckGeometry.layout(count: count, usableHeight: 926, columnWidth: 74,
                                             hover: .init(cursorY: rest.frames[open].maxY - rest.slices[open] / 2))
            for neighbour in [open - 1, open + 1] where neighbour >= 0 && neighbour < count - 1 {
                let top = opened.frames[neighbour].maxY
                var depth: CGFloat = 1
                while depth < opened.slices[neighbour] {
                    let point = CGPoint(x: 60, y: top - depth)
                    guard opened.tab(at: point) == neighbour else { depth += 4; continue }
                    let next = DeckGeometry.layout(count: count, usableHeight: 926, columnWidth: 74,
                                                   hover: .init(index: neighbour, cursorY: point.y))
                    if next.hovered != neighbour || next.tab(at: point) != neighbour { anywhere = false }
                    depth += 4
                }
            }
        }
    }
    expectTrue("hover: anywhere on a neighbour's slice opens that neighbour, under the cursor", anywhere)
}


// MARK: - Pinned notes

func runPinnedDeckTests() {
    func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    let full = EdgeMetrics.tabHeight
    let gap = EdgeMetrics.tabSpacing
    func deck(
        above: Int, pinned: Int, below: Int, height: CGFloat = 1000,
        scroll: CGFloat = 0, lowerScroll: CGFloat = 0, hover: DeckGeometry.Hover? = nil
    ) -> DeckGeometry {
        DeckGeometry.layout(
            count: above + pinned + below, usableHeight: height, columnWidth: 74,
            scrollOffset: scroll, lowerScrollOffset: lowerScroll,
            pinned: .init(above: above, count: pinned), hover: hover)
    }
    func blockRange(_ g: DeckGeometry, above: Int, pinned: Int) -> Range<Int> { above..<(above + pinned) }
    /// The middle of the pinned block, in the panel's coordinates.
    func blockMiddle(_ g: DeckGeometry, above: Int, pinned: Int) -> CGFloat {
        let block = g.frames[above..<(above + pinned)]
        return ((block.first!.maxY + block.last!.minY) / 2) + g.columnBottom
    }

    // The deck without a block is the deck it always was.
    let plain = DeckGeometry.layout(count: 24, usableHeight: 1000, columnWidth: 74)
    expectTrue("pinned: an empty block is no block",
               DeckGeometry.layout(count: 24, usableHeight: 1000, columnWidth: 74, pinned: .init(above: 24, count: 0)) == plain)
    expect("pinned: a plain deck has chrome at its foot", f(plain.chromeBottom), "0.00")

    // a. The block is centred on the deck's height — the screen's — however many
    // tabs there are around it.
    var centred = true, fills = true
    var offenders: [String] = []
    for pinned in 1...5 {
        for above in [0, 1, 2, 5, 9, 14, 30] {
            for below in [0, 1, 2, 5, 9, 14, 30] {
                let g = deck(above: above, pinned: pinned, below: below)
                if abs(blockMiddle(g, above: above, pinned: pinned) - g.deckHeight / 2) > 0.01 {
                    centred = false
                    offenders.append("\(above)/\(pinned)/\(below)")
                }
                if g.deckHeight > 1000 + 0.01 { fills = false }
            }
        }
    }
    expectTrue("pinned: the block is centred on the deck's height \(offenders.prefix(3))", centred)
    expectTrue("pinned: the deck never runs past the screen", fills)

    // b. Pinned tabs are always whole and never overlapped: full height,
    // full slice, a gap apart — whatever is around them, and whatever is open.
    var whole = true, apart = true, clear = true
    for pinned in 1...5 {
        for (above, below) in [(0, 0), (3, 3), (12, 12), (40, 40), (70, 2), (2, 70)] {
            let rest = deck(above: above, pinned: pinned, below: below)
            let count = above + pinned + below
            var states: [DeckGeometry] = [rest]
            for index in stride(from: 0, to: count, by: max(1, count / 9)) {
                states.append(deck(above: above, pinned: pinned, below: below,
                                   hover: .init(index: index, cursorY: rest.frames[index].midY)))
            }
            for g in states {
                for index in above..<(above + pinned) {
                    if g.slices[index] != full || g.frames[index].height != full || g.alphas[index] != 1 { whole = false }
                    if index > above, abs((g.frames[index - 1].minY - g.frames[index].maxY) - gap) > 0.01 { apart = false }
                    for other in 0..<count where other != index && !(above..<(above + pinned)).contains(other) {
                        // What of the other tab can be seen: its slice, in its side's clip.
                        let b = g.frames[other]
                        let shown = CGRect(x: b.minX, y: b.maxY - g.slices[other], width: b.width, height: g.slices[other])
                            .intersection(g.clip(of: other))
                        let a = g.frames[index]
                        if g.alphas[other] > 0.01 && !shown.isNull && a.minY < shown.maxY - 0.01 && shown.minY < a.maxY - 0.01 { clear = false }
                    }
                }
            }
        }
    }
    expectTrue("pinned: always full height with the label in view", whole)
    expectTrue("pinned: a gap apart", apart)
    expectTrue("pinned: nothing is drawn over them", clear)

    // c. Few notes: the unpinned ones hug the block from both sides.
    let few = deck(above: 2, pinned: 3, below: 2)
    expect("pinned: the side above ends a gap over the block", f(few.frames[1].minY - few.frames[2].maxY), f(gap))
    expect("pinned: the side below starts a gap under it", f(few.frames[4].minY - few.frames[5].maxY), f(gap))
    expect("pinned: the side above is spaced like any short deck", f(few.frames[0].minY - few.frames[1].maxY), f(gap))
    expectTrue("pinned: short sides do not overlap or scroll", few.mode == .spaced && few.hiddenCount == 0 && !few.showsOverflow)
    expect("pinned: and the deck is only as tall as it needs", f(few.deckHeight < 1000 ? 1 : 0), "1.00")
    expect("pinned: a deck of only pinned notes", f(deck(above: 0, pinned: 5, below: 0).deckHeight > 5 * full ? 1 : 0), "1.00")
    let lone = deck(above: 0, pinned: 1, below: 0)
    expect("pinned: one pinned note alone", String(lone.frames.count), "1")
    expect("pinned: sits on the middle of the deck", f(blockMiddle(lone, above: 0, pinned: 1)), f(lone.deckHeight / 2))

    // d. A side that does not fit packs, then scrolls, in its own room.
    let busy = deck(above: 30, pinned: 5, below: 30)
    expectTrue("pinned: crowded sides scroll", busy.mode == .scrolling && busy.showsOverflow)
    expect("pinned: and the deck takes the screen", f(busy.deckHeight), "1000.00")
    expectTrue("pinned: with something out of sight", busy.hiddenCount > 0)
    expectTrue("pinned: both sides can scroll", busy.maxScrollOffset > 0 && busy.lowerMaxScrollOffset > 0)
    let upperMoved = deck(above: 30, pinned: 5, below: 30, scroll: 120)
    expectTrue("pinned: scrolling the upper side leaves the lower one", (35..<65).allSatisfy { upperMoved.frames[$0] == busy.frames[$0] })
    expectTrue("pinned: and the block", (30..<35).allSatisfy { upperMoved.frames[$0] == busy.frames[$0] })
    expectTrue("pinned: and moves the upper side", upperMoved.frames[0] != busy.frames[0])
    let lowerMoved = deck(above: 30, pinned: 5, below: 30, lowerScroll: 120)
    expectTrue("pinned: scrolling the lower side leaves the upper one", (0..<35).allSatisfy { lowerMoved.frames[$0] == busy.frames[$0] })
    expectTrue("pinned: and moves the lower side", lowerMoved.frames[40] != busy.frames[40])
    expect("pinned: clamped at the far end", f(deck(above: 30, pinned: 5, below: 30, scroll: 99_999).scrollOffset), f(busy.maxScrollOffset))
    expect("pinned: and at the near end", f(deck(above: 30, pinned: 5, below: 30, lowerScroll: -50).lowerScrollOffset), "0.00")
    let atEnd = deck(above: 30, pinned: 5, below: 30, lowerScroll: 99_999)
    expect("pinned: scrolled to the end, the last tab rests on the foot of the column", f(atEnd.frames[64].minY), "0.00")
    expect("pinned: the chrome sits under the column", f(atEnd.chromeBottom + EdgeMetrics.plusTopMargin + EdgeMetrics.plusDiameter
        + EdgeMetrics.overflowHeight + EdgeMetrics.tabSpacing), f(atEnd.columnBottom))

    // The part the wheel turns follows the side of the block.
    expectTrue("pinned: over the upper side the wheel moves the upper side",
               busy.scrollPart(atY: busy.frames[0].midY) == .upper)
    expectTrue("pinned: over the lower side, the lower one",
               busy.scrollPart(atY: busy.frames[64].midY) == .lower)
    expectTrue("pinned: over the block, the nearer side",
               busy.scrollPart(atY: busy.frames[31].midY) == .upper && busy.scrollPart(atY: busy.frames[33].midY) == .lower)
    expectTrue("pinned: without a block it is all one", plain.scrollPart(atY: 5) == .upper)

    // e. Everything stays inside the column, on screens of any height.
    var inside = true, room = true
    var places: [String] = []
    for height in [600, 700, 900, 1000, 1400] as [CGFloat] {
        for pinned in 1...5 {
            for (above, below) in [(0, 0), (1, 1), (3, 5), (10, 10), (40, 40), (0, 12), (12, 0)] {
                // A screen too short for the block and a whole tab on each
                // side (and the foot of the column) cannot show everything.
                let needed = CGFloat(pinned) * (full + gap) + (above > 0 ? full + gap : 0) + (below > 0 ? full + gap : 0)
                    + EdgeMetrics.plusTopMargin + EdgeMetrics.plusDiameter + EdgeMetrics.overflowHeight + gap
                if needed > height { continue }
                let g = deck(above: above, pinned: pinned, below: below, height: height)
                if g.deckHeight > height + 0.01 { inside = false; places.append("tall \(above)/\(pinned)/\(below)@\(Int(height))") }
                for (index, frame) in g.frames.enumerated() where g.alphas[index] > 0.999 {
                    // The part that shows is the slice from the tab's top.
                    if frame.maxY - g.slices[index] < -0.01 || frame.maxY > g.columnHeight + 0.01 {
                        inside = false
                        places.append("out \(above)/\(pinned)/\(below)@\(Int(height))")
                    }
                }
                // Each side that has tabs has room for at least one whole tab.
                if below > 0 && g.frames[above + pinned].minY < -0.01 { room = false }
                if above > 0 && g.frames[above - 1].maxY > g.columnHeight + 0.01 { room = false }
            }
        }
    }
    expectTrue("pinned: every tab is inside the column \(places.prefix(4))", inside)
    expectTrue("pinned: a short screen still has room for the sides", room)
    let squeezed = deck(above: 4, pinned: 5, below: 4, height: 700)
    expectTrue("pinned: five pinned on a short screen move the block up rather than off the bottom",
               blockMiddle(squeezed, above: 4, pinned: 5) > squeezed.deckHeight / 2)

    // f. The cursor: sweeping down or up the column reaches every tab in view,
    // and what it opens is the tab it is over.
    func sweep(_ g0: DeckGeometry, above: Int, pinned: Int, below: Int, height: CGFloat, from start: CGFloat, to end: CGFloat, step: CGFloat)
        -> (opened: Set<Int>, wrong: Int) {
        var layout = g0
        var opened = Set<Int>()
        var wrong = 0
        var y = start
        while start < end ? y <= end : y >= end {
            if let index = layout.tab(at: CGPoint(x: 60, y: y)) {
                if index != layout.hovered {
                    layout = deck(above: above, pinned: pinned, below: below, height: height,
                                  scroll: g0.scrollOffset, lowerScroll: g0.lowerScrollOffset,
                                  hover: .init(index: index, cursorY: y))
                }
                if let open = layout.hovered {
                    opened.insert(open)
                    // Within a few points of where a side ends the open tab
                    // cannot also stay put and whole — as at either end of a
                    // plain scrolling deck.
                    let side = layout.clip(of: open)
                    if layout.tab(at: CGPoint(x: 60, y: y)) != open, y - side.minY > 8, side.maxY - y > 8 { wrong += 1 }
                }
            }
            y += start < end ? step : -step
        }
        return (opened, wrong)
    }
    func inView(_ g: DeckGeometry) -> Set<Int> {
        // A tab is in view when some of its slice shows inside its side's clip.
        Set(g.frames.indices.filter { index in
            let frame = g.frames[index]
            let shown = CGRect(x: frame.minX, y: frame.maxY - g.slices[index], width: frame.width, height: g.slices[index])
                .intersection(g.clip(of: index))
            return !shown.isNull && shown.height >= 4 && shown.midY > 0 && shown.midY < g.columnHeight && g.alphas[index] > 0.05
        })
    }
    var reached = true, steady = true
    var missed: [String] = []
    for height in [700, 926, 1300] as [CGFloat] {
        for pinned in [1, 3, 5] {
            for (above, below) in [(0, 0), (2, 3), (9, 9), (20, 20), (60, 4), (4, 60), (50, 50)] {
                let needed = CGFloat(pinned) * (full + gap) + 2 * (full + gap) + 2 * EdgeMetrics.plusDiameter + 40
                if needed > height { continue }
                let rest = deck(above: above, pinned: pinned, below: below, height: height)
                let top = rest.columnHeight - 1
                let down = sweep(rest, above: above, pinned: pinned, below: below, height: height, from: top, to: 1, step: 3)
                let up = sweep(rest, above: above, pinned: pinned, below: below, height: height, from: 1, to: top, step: 3)
                if !inView(rest).isSubset(of: down.opened) || !inView(rest).isSubset(of: up.opened) {
                    reached = false
                    missed.append("\(above)/\(pinned)/\(below)@\(Int(height))")
                }
                if down.wrong > 0 || up.wrong > 0 { steady = false }
            }
        }
    }
    expectTrue("pinned sweep: moving slowly opens every tab in view \(missed.prefix(4))", reached)
    expectTrue("pinned sweep: the tab opened is always the one under the cursor", steady)

    // Opening a tab on one side moves nothing on the other, nor the block.
    var still = true
    let rest = deck(above: 14, pinned: 3, below: 14)
    for open in 0..<31 where !(14..<17).contains(open) {
        let g = deck(above: 14, pinned: 3, below: 14, hover: .init(index: open, cursorY: rest.frames[open].midY))
        let others = (0..<31).filter { index in
            index != open && (open < 14 ? index >= 14 : index < 17)
        }
        if !others.allSatisfy({ g.frames[$0] == rest.frames[$0] }) { still = false }
        if g.hovered != open { still = false }
    }
    expectTrue("pinned hover: opening a tab leaves the block and the other side alone", still)
    let lifted = deck(above: 14, pinned: 3, below: 14, hover: .init(index: 15, cursorY: rest.frames[15].midY))
    expect("pinned hover: a pinned tab reaches out like any other", f(lifted.frames[15].width), f(EdgeMetrics.tabWidth + EdgeMetrics.hoverLift))
    expectTrue("pinned hover: and stays where it is", lifted.frames[15].minY == rest.frames[15].minY && lifted.frames[15].maxX == 74)
    expectTrue("pinned hover: the cursor finds a pinned tab with nothing open",
               deck(above: 14, pinned: 3, below: 14, hover: .init(cursorY: rest.frames[15].midY)).hovered == 15)
    expectTrue("pinned hover: and an overlapped one on either side",
               deck(above: 14, pinned: 3, below: 14, hover: .init(cursorY: rest.frames[3].maxY - 4)).hovered == 3
               && deck(above: 14, pinned: 3, below: 14, hover: .init(cursorY: rest.frames[25].maxY - 4)).hovered == 25)
}
