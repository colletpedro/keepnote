import CoreGraphics

/// Where every tab of a fanned deck goes, worked out from nothing but the
/// number of notes and the height the screen leaves for the deck.
///
/// Three stages, in order, as notes are added:
///
/// 1. **Spaced.** Every tab at full height, `tabSpacing` apart, the deck as
///    tall as they need.
/// 2. **Packed.** They no longer fit: the deck takes the whole height and the
///    step between tabs shrinks — first the gaps, then into overlap, each tab
///    covering the bottom of the one above it — by exactly as much as it
///    takes for all of them to fit, the last one still whole.
/// 3. **Scrolling.** The step would go under `minimumVisibleSlice`: it stays
///    there, the column scrolls, and a "+N" chip counts what is out of sight.
///
/// With the cursor over a tab (`Hover`), that tab reaches `hoverLift` further
/// out; where tabs overlap it is also uncovered entirely, the two tabs on
/// either side open part of the way, and the rest close up to make the room,
/// so the first and last tabs stay where they are. The open tab keeps its
/// place under the cursor.
///
/// With pinned notes (`PinnedBlock`) the deck is three parts, top to bottom:
/// the unpinned tabs above, the pinned block, the unpinned tabs below. The
/// block is `tabHeight` tabs `tabSpacing` apart, never overlapped, and
/// centred on the deck's height — which, with pinned notes, is the screen's.
/// Each side then lays out and scrolls on its own, in the room the block
/// leaves it, exactly as an unpinned deck would in a column that size; the
/// side above ends at the block and the side below starts at it.
///
/// Coordinates are the column's: origin at its bottom left, y up, tab 0 at
/// the top. Nothing here knows about views, so all of it is tested directly.
struct DeckGeometry: Equatable {
    enum Mode: Equatable {
        case spaced
        case packed
        case scrolling
    }

    var mode: Mode
    /// Distance from one tab's top to the next one's.
    var step: CGFloat
    /// Each tab's frame in the column, scrolled.
    var frames: [CGRect]
    /// How much of each tab shows, measured down from its top: the part the
    /// tab below does not cover. The last tab always shows whole.
    var slices: [CGFloat]
    /// Opacity of each tab: tabs scrolled to the edge of the column fade over
    /// the last few points instead of being cut.
    var alphas: [CGFloat]
    /// The column the tabs scroll in, and the deck around it: the column, the
    /// "+N" chip when scrolling, and the "+".
    var columnHeight: CGFloat
    var columnBottom: CGFloat
    var deckHeight: CGFloat
    var scrollOffset: CGFloat
    var maxScrollOffset: CGFloat
    /// Tabs with nothing showing in the column — the chip's "+N".
    var hiddenCount: Int
    /// The tab under the cursor, lifted.
    var hovered: Int?

    /// The pinned block this was laid out around, if there was one.
    var pinned: PinnedBlock?
    /// Where the "+" and the "+N" chip sit: the deck's own bottom when it has
    /// no pinned block, and wherever the part below the block ends when it
    /// has one.
    var chromeBottom: CGFloat = 0
    /// With a pinned block: the part of the column each side shows its tabs in,
    /// the upper one ending at the block and the lower one at the column's foot.
    var upperClip: CGRect = .zero
    var lowerClip: CGRect = .zero
    /// The part below the pinned block scrolls on its own.
    var lowerScrollOffset: CGFloat = 0
    var lowerMaxScrollOffset: CGFloat = 0

    /// The pinned notes in the deck's order: `above` unpinned tabs come
    /// first, then the `count` pinned ones, then the rest.
    struct PinnedBlock: Equatable {
        var above: Int
        var count: Int
    }

    /// Which part of the deck scrolls when the wheel turns over a point.
    enum ScrollPart: Equatable {
        case upper
        case lower
    }

    /// The part the wheel moves over `y` (column coordinates): the whole deck
    /// when nothing is pinned; otherwise the side of the block `y` is on.
    func scrollPart(atY y: CGFloat) -> ScrollPart {
        guard let pinned, pinned.count > 0, frames.count >= pinned.above + pinned.count else { return .upper }
        let block = frames[pinned.above..<(pinned.above + pinned.count)]
        let middle = ((block.first?.maxY ?? 0) + (block.last?.minY ?? 0)) / 2
        return y >= middle ? .upper : .lower
    }

    /// The cursor over the column. `index` is the tab it is over, as the
    /// deck is drawn right now; nil to take whichever tab the cursor is over
    /// in the deck at rest.
    struct Hover: Equatable {
        var index: Int?
        var cursorY: CGFloat
    }

    /// The tab drawn at `point`, in column coordinates. Lower tabs are drawn
    /// over upper ones, so they are asked first. A tab only exists where its
    /// side shows it: the unpinned tabs above the block stop at the block, the
    /// ones below it stop at the foot of the column.
    func tab(at point: CGPoint) -> Int? {
        guard point.y >= 0, point.y <= columnHeight else { return nil }
        return frames.indices.reversed().first { index in
            frames[index].contains(point) && alphas[index] > 0.01 && clip(of: index).contains(point)
        }
    }

    /// Where tab `index` can be seen: the whole column, or — around a pinned
    /// block — the part of it that belongs to the tab's side.
    func clip(of index: Int) -> CGRect {
        let column = CGRect(x: 0, y: 0, width: frames.first?.maxX ?? 0, height: columnHeight)
        guard let pinned, pinned.count > 0 else { return column }
        if index < pinned.above { return upperClip }
        if index >= pinned.above + pinned.count { return lowerClip }
        return column
    }

    var showsOverflow: Bool { mode == .scrolling }

    struct Metrics: Equatable {
        var tabHeight = EdgeMetrics.tabHeight
        var tabWidth = EdgeMetrics.tabWidth
        var spacing = EdgeMetrics.tabSpacing
        var minimumSlice = EdgeMetrics.minimumVisibleSlice
        /// The "+" and the margin above it, under the column.
        var plusZone = EdgeMetrics.plusTopMargin + EdgeMetrics.plusDiameter
        /// The "+N" chip and its gap, added under the column when scrolling.
        var overflowZone = EdgeMetrics.overflowHeight + EdgeMetrics.tabSpacing
        var fade: CGFloat = 26
        var hoverLift = EdgeMetrics.hoverLift
        /// How far the tabs next to an open one open, as a share of the way
        /// from the resting step to a whole tab: one away, then two away.
        var neighbourOpening: [CGFloat] = [0.5, 0.22]
        /// The least of a tab that shows while another is open beside it.
        var squeezedSlice: CGFloat = 10
        /// How far inside the open tab the cursor is kept from its ends. Small
        /// on purpose: a sweep down the deck leaves each open tab across its
        /// bottom edge, and every point of margin pushes the next one down.
        var cursorMargin: CGFloat = 2
    }

    /// How many tabs `usableHeight` holds before the deck has to scroll.
    static func capacity(usableHeight: CGFloat, metrics: Metrics = Metrics()) -> Int {
        let column = usableHeight - metrics.plusZone
        guard column >= metrics.tabHeight else { return 1 }
        return Int(((column - metrics.tabHeight) / metrics.minimumSlice).rounded(.down)) + 1
    }

    static func layout(
        count: Int,
        usableHeight: CGFloat,
        columnWidth: CGFloat,
        scrollOffset: CGFloat = 0,
        lowerScrollOffset: CGFloat = 0,
        pinned: PinnedBlock? = nil,
        hover: Hover? = nil,
        metrics: Metrics = Metrics()
    ) -> DeckGeometry {
        if let pinned, pinned.count > 0, pinned.above + pinned.count <= count {
            return layoutAround(
                pinned, count: count, usableHeight: usableHeight, columnWidth: columnWidth,
                scrollOffset: scrollOffset, lowerScrollOffset: lowerScrollOffset, hover: hover, metrics: metrics
            )
        }
        let height = metrics.tabHeight
        let spacedStep = height + metrics.spacing
        let packedColumn = max(height, usableHeight - metrics.plusZone)

        var mode = Mode.spaced
        var step = spacedStep
        var column: CGFloat
        var bottom = metrics.plusZone

        let spacedHeight = CGFloat(count) * height + CGFloat(max(0, count - 1)) * metrics.spacing
        if count <= 1 || spacedHeight <= packedColumn {
            column = count == 0 ? 0 : spacedHeight
        } else {
            let fitting = (packedColumn - height) / CGFloat(count - 1)
            if fitting >= metrics.minimumSlice {
                mode = .packed
                step = min(spacedStep, fitting)
                column = packedColumn
            } else {
                mode = .scrolling
                step = metrics.minimumSlice
                bottom += metrics.overflowZone
                column = max(height, usableHeight - bottom)
            }
        }

        let content = count == 0 ? 0 : CGFloat(count - 1) * step + height
        let maxScroll = max(0, content - column)
        let offset = min(maxScroll, max(0, scrollOffset))

        // Each tab's top, measured down from the top of the content.
        var tops = (0..<count).map { CGFloat($0) * step }
        var hovered: Int?
        if let hover, count > 0 {
            let cursor = column - hover.cursorY + offset
            let resting = (0..<count).last { tops[$0] <= cursor && cursor <= tops[$0] + height }
            if let index = hover.index ?? resting, index < count {
                if step < height {
                    // While scrolling, only the tabs in view make room, between
                    // the first and the last one showing, which stay put — so
                    // opening a tab never pushes another out of sight.
                    let restingTops = tops
                    var first = 0
                    var last = count - 1
                    if mode == .scrolling {
                        first = (0..<count).first { restingTops[$0] + step > offset } ?? 0
                        last = (0..<count).last { restingTops[$0] < offset + column } ?? count - 1
                        first = min(first, index)
                        last = max(last, min(count - 1, index + 1))
                    }
                    hovered = index
                    tops = openTops(restingTops, step: step, first: first, last: last,
                                    open: index, cursor: cursor, metrics: metrics)
                } else {
                    hovered = index
                }
            }
        }

        var frames: [CGRect] = []
        var slices: [CGFloat] = []
        var alphas: [CGFloat] = []
        var hidden = 0
        for index in 0..<count {
            let top = tops[index]
            let slice = index == count - 1 ? height : min(height, tops[index + 1] - top)
            let y = column - top - height + offset
            let lift = index == hovered ? metrics.hoverLift : 0
            frames.append(CGRect(x: columnWidth - metrics.tabWidth - lift, y: y,
                                 width: metrics.tabWidth + lift, height: height))
            slices.append(slice)

            // The part of the tab that shows, against the column's edges.
            let shownTop = y + height
            let shownBottom = shownTop - slice
            var alpha: CGFloat = 1
            if shownBottom < 0 { alpha = max(0, 1 + shownBottom / metrics.fade) }
            if shownTop > column { alpha = min(alpha, max(0, 1 - (shownTop - column) / metrics.fade)) }
            alphas.append(alpha)
            if shownTop <= 2 || shownBottom >= column - 2 { hidden += 1 }
        }

        return DeckGeometry(
            mode: mode, step: step, frames: frames, slices: slices, alphas: alphas,
            columnHeight: column, columnBottom: bottom, deckHeight: column + bottom,
            scrollOffset: offset, maxScrollOffset: maxScroll, hiddenCount: hidden, hovered: hovered
        )
    }

    // MARK: - Around a pinned block

    /// The deck with a pinned block in the middle. Worked in coordinates
    /// measured from the middle of the deck's height, y up, and moved into the
    /// column's at the end.
    private static func layoutAround(
        _ block: PinnedBlock,
        count: Int,
        usableHeight: CGFloat,
        columnWidth: CGFloat,
        scrollOffset: CGFloat,
        lowerScrollOffset: CGFloat,
        hover: Hover?,
        metrics: Metrics
    ) -> DeckGeometry {
        let height = metrics.tabHeight
        let gap = metrics.spacing
        let above = block.above
        let below = count - above - block.count
        let blockHeight = CGFloat(block.count) * height + CGFloat(block.count - 1) * gap
        let half = usableHeight / 2

        // Each side is an ordinary deck in the room the block leaves it. The
        // "+" lives under the lower side, and so does the "+N" chip once
        // either side scrolls; the block moves up only as far as the lower
        // side needs to hold one whole tab, or down for the upper one.
        var side = metrics
        side.plusZone = 0
        side.overflowZone = 0
        func rooms(chip: Bool) -> (upper: CGFloat, lower: CGFloat, shift: CGFloat) {
            let zone = metrics.plusZone + (chip ? metrics.overflowZone : 0)
            let upper = half - blockHeight / 2 - gap
            let lower = half - blockHeight / 2 - gap - zone
            var shift: CGFloat = 0
            if below > 0 { shift = max(shift, height - lower) }
            if above > 0 {
                let most = upper - height
                // Both sides want the room and it is not there: they share it.
                shift = shift <= most ? shift : (above > 0 && below > 0 ? (upper - lower) / 2 : shift)
            }
            return (upper - shift, lower + shift, shift)
        }
        func sides(_ room: (upper: CGFloat, lower: CGFloat, shift: CGFloat), upperHover: Hover? = nil, lowerHover: Hover? = nil)
            -> (DeckGeometry, DeckGeometry) {
            (layout(count: above, usableHeight: room.upper, columnWidth: columnWidth, scrollOffset: scrollOffset,
                    hover: upperHover, metrics: side),
             layout(count: below, usableHeight: room.lower, columnWidth: columnWidth, scrollOffset: lowerScrollOffset,
                    hover: lowerHover, metrics: side))
        }

        var chip = false
        var room = rooms(chip: false)
        var (upper, lower) = sides(room)
        if upper.mode == .scrolling || lower.mode == .scrolling {
            chip = true
            room = rooms(chip: true)
            (upper, lower) = sides(room)
        }
        let shift = room.shift

        // Where each part starts, measured from the middle.
        let upperBase = shift + blockHeight / 2 + gap          // bottom of the upper side
        let lowerTop = shift - blockHeight / 2 - gap           // top of the lower side
        let blockTop = shift + blockHeight / 2

        // A hover given in the column's coordinates is only known once the
        // extent of the whole deck is; the column's origin is the bottom of the
        // lower side (or of the block, without one).
        let bottom = below > 0 ? lowerTop - lower.columnHeight : blockTop - blockHeight
        let topEdge = above > 0 ? upperBase + upper.columnHeight : blockTop
        let zones = metrics.plusZone + (chip ? metrics.overflowZone : 0)
        let extent = min(half, max(topEdge, -(bottom - zones)))
        let columnBottomInMiddle = bottom
        func middleY(fromColumn y: CGFloat) -> CGFloat { y + columnBottomInMiddle }

        var hovered: Int?
        if let hover {
            let cursor = middleY(fromColumn: hover.cursorY)
            var index = hover.index
            if index == nil {
                // The tab drawn under the cursor with nothing open.
                var resting: [CGRect] = upper.frames.map { shifted($0, by: upperBase) }
                resting += pinnedFrames(block, blockTop: blockTop, width: columnWidth, metrics: metrics)
                resting += lower.frames.map { shifted($0, by: lowerTop - lower.columnHeight) }
                index = resting.indices.reversed().first { resting[$0].minY <= cursor && cursor <= resting[$0].maxY }
            }
            if let index, index < count {
                hovered = index
                if index < above {
                    (upper, lower) = sides(room, upperHover: Hover(index: index, cursorY: cursor - upperBase))
                } else if index >= above + block.count {
                    (upper, lower) = sides(room, lowerHover: Hover(
                        index: index - above - block.count, cursorY: cursor - (lowerTop - lower.columnHeight)))
                }
            }
        }

        // Everything in the column's coordinates, in the deck's order.
        var frames = upper.frames.map { shifted($0, by: upperBase - columnBottomInMiddle) }
        var pinnedBlockFrames = pinnedFrames(block, blockTop: blockTop - columnBottomInMiddle, width: columnWidth, metrics: metrics)
        if let hovered, hovered >= above, hovered < above + block.count {
            let local = hovered - above
            var frame = pinnedBlockFrames[local]
            frame.origin.x -= metrics.hoverLift
            frame.size.width += metrics.hoverLift
            pinnedBlockFrames[local] = frame
        }
        frames += pinnedBlockFrames
        frames += lower.frames.map { shifted($0, by: lowerTop - lower.columnHeight - columnBottomInMiddle) }

        let deckHeight = 2 * extent
        let columnBottom = columnBottomInMiddle + extent
        let modes = [upper, lower].filter { !$0.frames.isEmpty }.map(\.mode)
        let mode: Mode = modes.contains(.scrolling) ? .scrolling : (modes.contains(.packed) ? .packed : .spaced)
        let steps = [upper, lower].filter { !$0.frames.isEmpty }.map(\.step)
        return DeckGeometry(
            mode: mode,
            step: steps.min() ?? height + gap,
            frames: frames,
            slices: upper.slices + Array(repeating: height, count: block.count) + lower.slices,
            alphas: upper.alphas + Array(repeating: 1, count: block.count) + lower.alphas,
            columnHeight: deckHeight - columnBottom,
            columnBottom: columnBottom,
            deckHeight: deckHeight,
            scrollOffset: upper.scrollOffset,
            maxScrollOffset: upper.maxScrollOffset,
            hiddenCount: upper.hiddenCount + lower.hiddenCount,
            hovered: hovered,
            pinned: block,
            chromeBottom: columnBottom - zones,
            upperClip: CGRect(x: 0, y: upperBase - columnBottomInMiddle, width: columnWidth,
                              height: max(0, deckHeight - columnBottom - (upperBase - columnBottomInMiddle))),
            lowerClip: CGRect(x: 0, y: 0, width: columnWidth, height: max(0, lowerTop - columnBottomInMiddle)),
            lowerScrollOffset: lower.scrollOffset,
            lowerMaxScrollOffset: lower.maxScrollOffset
        )
    }

    private static func shifted(_ rect: CGRect, by dy: CGFloat) -> CGRect {
        rect.offsetBy(dx: 0, dy: dy)
    }

    /// The pinned tabs, full height and `spacing` apart, top to bottom from
    /// `blockTop`, flush with the column's right edge.
    private static func pinnedFrames(_ block: PinnedBlock, blockTop: CGFloat, width: CGFloat, metrics: Metrics) -> [CGRect] {
        (0..<block.count).map { index in
            let top = blockTop - CGFloat(index) * (metrics.tabHeight + metrics.spacing)
            return CGRect(x: width - metrics.tabWidth, y: top - metrics.tabHeight,
                          width: metrics.tabWidth, height: metrics.tabHeight)
        }
    }

    /// Tops for overlapping tabs with tab `open` uncovered under `cursor`,
    /// re-spacing the tabs from `first` to `last`, whose own tops stay put.
    ///
    /// The slices above the open tab and those from it down are worked out
    /// separately, each side keeping its own total, which is what holds the
    /// open tab in place: its top only moves as far as it must to keep the
    /// cursor inside it, or for the side below to fit it whole.
    private static func openTops(
        _ resting: [CGFloat], step: CGFloat, first: Int, last: Int, open: Int, cursor: CGFloat, metrics: Metrics
    ) -> [CGFloat] {
        let height = metrics.tabHeight
        let floor = min(metrics.squeezedSlice, step)
        let origin = resting[first]
        let total = resting[last] - origin
        let cursor = cursor - origin
        let below = Array(open..<last)
        let required = (below.isEmpty ? 0 : height) + CGFloat(max(0, below.count - 1)) * floor

        func desired(_ index: Int) -> (CGFloat, Int) {
            let distance = abs(index - open)
            if distance == 0 { return (height, 0) }
            if distance <= metrics.neighbourOpening.count {
                return (step + (height - step) * metrics.neighbourOpening[distance - 1], distance)
            }
            return (step, metrics.neighbourOpening.count + 1)
        }
        /// The least a side can close up to without squeezing the tabs
        /// nearest the open one.
        func roomForNeighbours(_ members: [Int]) -> CGFloat {
            members.reduce(0) { sum, index in
                let (value, tier) = desired(index)
                return sum + (tier > metrics.neighbourOpening.count ? floor : value)
            }
        }

        // Where the open tab's top goes: where it rests, moved only as far as
        // its neighbours need for room on the short side, and never so far
        // that the cursor is no longer on it.
        let aboveMembers = Array(first..<open)
        var above = resting[open] - origin
        above = min(max(above, roomForNeighbours(aboveMembers)), total - roomForNeighbours(below))
        above = min(max(above, cursor + metrics.cursorMargin - height), cursor - metrics.cursorMargin)
        above = min(max(above, CGFloat(aboveMembers.count) * floor), total - required)
        above = max(above, CGFloat(aboveMembers.count) * floor)
        // Nothing above the first tab, nothing below the last: the end tabs
        // stay put.
        if open == first { above = 0 }
        if below.isEmpty { above = total }

        var slices: [Int: CGFloat] = [:]
        for (members, sum) in [(aboveMembers, above), (below, total - above)] where !members.isEmpty {
            var values = members.map { desired($0).0 }
            let tiers = members.map { desired($0).1 }
            var difference = sum - values.reduce(0, +)
            // Room to spare goes to the farthest tabs; room wanting is taken
            // from them first, down to the floor, and only then from tabs
            // nearer the open one.
            for tier in Set(tiers).sorted(by: >) where abs(difference) > 0.0001 {
                let positions = members.indices.filter { tiers[$0] == tier }
                if difference > 0 {
                    for position in positions { values[position] += difference / CGFloat(positions.count) }
                    difference = 0
                } else {
                    let available = positions.reduce(0) { $0 + max(0, values[$1] - floor) }
                    let taken = min(available, -difference)
                    guard available > 0 else { continue }
                    for position in positions {
                        values[position] -= taken * max(0, values[position] - floor) / available
                    }
                    difference += taken
                }
            }
            for (position, index) in members.enumerated() { slices[index] = values[position] }
        }

        var tops = resting
        for index in first..<last { tops[index + 1] = tops[index] + (slices[index] ?? step) }
        // The end of the run stays exactly where it was, rounding aside.
        tops[last] = resting[last]
        return tops
    }
}
