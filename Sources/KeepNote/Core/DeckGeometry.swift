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
/// out of the edge — and is drawn over its neighbours, which is the deck's
/// job to do (it brings the tab to the front); where tabs overlap it shows
/// whole. Nothing else moves: not a neighbour, not the first or last tab. Which
/// tab is under the cursor is decided by the deck at rest — the slice each
/// tab shows — so growing one never changes what the cursor is over, and a
/// sweep down the deck lifts every tab in turn.
///
/// With pinned notes (`PinnedBlock`) the deck is three parts, top to bottom:
/// the unpinned tabs above, the pinned block, the unpinned tabs below. The
/// block is `tabHeight` tabs `tabSpacing` apart, never overlapped, and
/// centred on the deck's height — which, with pinned notes, is the screen's.
/// Each side then lays out and scrolls on its own, in the room the block
/// leaves it, exactly as an unpinned deck would in a column that size; the
/// side above ends at the block and the side below starts at it.
///
/// With an open group (`DeckPlan`) its header and its notes are whole at every
/// stage (`whole`): nothing covers them, the tab after each starts a full step
/// down, and only the other tabs give way when the deck packs. When even then the
/// side's tabs do not fit, the header (the first tab) stays at the top of the
/// column (`stickyFirst`) and the rest scrolls in the room under it, clipped there.
///
/// Coordinates are the column's: origin at its bottom left, y up, tab 0 at
/// the top. Nothing here knows about views, so all of it is tested directly.
///
/// The tabs are flush with the column's right side, and a hovered one grows
/// leftwards; with the deck on the left edge (`edge`), the same layout is
/// mirrored, flush with the left side and growing rightwards.
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
    /// tab below does not cover. The last tab always shows whole. A hovered tab
    /// is drawn over the ones below it, so it shows whole too; its slice here
    /// is still the deck's, which is what decides which tab the cursor is on.
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
    /// How far a hovered tab reaches out of the edge, and which edge it is
    /// flush with: the cursor is over a tab from the lift's width away too.
    var lift: CGFloat = EdgeMetrics.hoverLift
    var edge: ScreenEdge = .right
    /// How far the raised tabs were taken out of the edge, if any were.
    var outset: CGFloat = 0

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
    /// The header that stays at the top while the tabs after it scroll
    /// (`stickyFirst`), when the side it heads did not fit: its index (always
    /// the first tab) and the part of the column the others show in, under it.
    var stickyHeader: Int?
    var stickyNotesClip: CGRect = .zero

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

    /// The tab the cursor is over at `point`, in column coordinates: the one
    /// whose slice of the deck at rest is there — lower tabs cover upper ones —
    /// reaching `lift` further towards the middle of the screen, as a hovered
    /// tab does. A tab only exists where its side shows it: the unpinned tabs
    /// above the block stop at the block, the ones below it stop at the foot
    /// of the column.
    func tab(at point: CGPoint) -> Int? {
        guard point.y >= 0, point.y <= columnHeight else { return nil }
        return frames.indices.reversed().first { index in
            alphas[index] > 0.01 && clip(of: index).contains(point) && hitArea(of: index).contains(point)
        }
    }

    /// The part of tab `index` the cursor counts as over.
    func hitArea(of index: Int) -> CGRect {
        let frame = frames[index]
        var area = CGRect(x: frame.minX, y: frame.maxY - slices[index], width: frame.width, height: slices[index])
        if index != hovered {
            // A tab that is not lifted still answers where it would reach.
            if edge == .right { area.origin.x -= lift }
            area.size.width += lift
        }
        return area
    }

    /// Where tab `index` can be seen: the whole column, or — around a pinned
    /// block — the part of it that belongs to the tab's side.
    func clip(of index: Int) -> CGRect {
        let column = CGRect(x: 0, y: 0, width: frames.first?.maxX ?? 0, height: columnHeight)
        if let sticky = stickyHeader {
            // The header is seen over the whole of its side; what follows it
            // is only seen under it.
            let end = pinned?.above ?? frames.count
            if index == sticky { return pinned == nil ? column : upperClip }
            if index < end { return stickyNotesClip }
        }
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
        /// How far a hovered tab reaches out of the edge: Settings > Deck >
        /// Hover magnification. Nothing, with it off.
        var hoverLift = EdgeMetrics.hoverLift
        /// How much further out of the edge the `raised` tabs stand.
        var outset = EdgeMetrics.groupOutset
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
        stickyFirst: Bool = false,
        whole: Set<Int> = [],
        raised: Set<Int> = [],
        heights: [Int: CGFloat] = [:],
        edge: ScreenEdge,
        metrics: Metrics = Metrics()
    ) -> DeckGeometry {
        var geometry = layout(
            count: count, usableHeight: usableHeight, columnWidth: columnWidth, scrollOffset: scrollOffset,
            lowerScrollOffset: lowerScrollOffset, pinned: pinned, hover: hover, stickyFirst: stickyFirst,
            whole: whole, raised: raised, heights: heights, metrics: metrics)
        geometry.frames = geometry.frames.map { edge.mirrored($0, in: columnWidth) }
        geometry.edge = edge
        return geometry
    }

    /// The layout for the right edge. The `raised` tabs (an open group's notes)
    /// stand `metrics.outset` further out of the edge than the others.
    static func layout(
        count: Int,
        usableHeight: CGFloat,
        columnWidth: CGFloat,
        scrollOffset: CGFloat = 0,
        lowerScrollOffset: CGFloat = 0,
        pinned: PinnedBlock? = nil,
        hover: Hover? = nil,
        stickyFirst: Bool = false,
        whole: Set<Int> = [],
        raised: Set<Int> = [],
        heights: [Int: CGFloat] = [:],
        metrics: Metrics = Metrics()
    ) -> DeckGeometry {
        var geometry = flatLayout(
            count: count, usableHeight: usableHeight, columnWidth: columnWidth, scrollOffset: scrollOffset,
            lowerScrollOffset: lowerScrollOffset, pinned: pinned, hover: hover, stickyFirst: stickyFirst,
            whole: whole, heights: heights, metrics: metrics)
        for index in raised where geometry.frames.indices.contains(index) {
            geometry.frames[index].origin.x -= metrics.outset
            geometry.frames[index].size.width += metrics.outset
        }
        geometry.outset = raised.isEmpty ? 0 : metrics.outset
        return geometry
    }

    private static func flatLayout(
        count: Int,
        usableHeight: CGFloat,
        columnWidth: CGFloat,
        scrollOffset: CGFloat,
        lowerScrollOffset: CGFloat,
        pinned: PinnedBlock?,
        hover: Hover?,
        stickyFirst: Bool,
        whole: Set<Int>,
        heights: [Int: CGFloat],
        metrics: Metrics
    ) -> DeckGeometry {
        if let pinned, pinned.count > 0, pinned.above + pinned.count <= count {
            return layoutAround(
                pinned, count: count, usableHeight: usableHeight, columnWidth: columnWidth,
                scrollOffset: scrollOffset, lowerScrollOffset: lowerScrollOffset, hover: hover,
                stickyFirst: stickyFirst, whole: whole, heights: heights, metrics: metrics
            )
        }
        if stickyFirst, count > 1 {
            let plain = layout(count: count, usableHeight: usableHeight, columnWidth: columnWidth,
                               scrollOffset: scrollOffset, hover: hover, whole: whole, heights: heights, metrics: metrics)
            if plain.mode == .scrolling {
                return stickyLayout(count: count, usableHeight: usableHeight, columnWidth: columnWidth,
                                    scrollOffset: scrollOffset, hover: hover, whole: whole, heights: heights, metrics: metrics)
            }
            return plain
        }
        let height = metrics.tabHeight
        let spacedStep = height + metrics.spacing
        func tabHeight(_ index: Int) -> CGFloat { max(height, heights[index] ?? height) }
        // A whole tab is never covered: the tab after it starts a whole step
        // down, so only the other tabs give way when the deck packs.
        let wholeIndices = whole.filter { $0 >= 0 && $0 < count - 1 }
        let wholeSteps = wholeIndices.count
        let wholeExtent = wholeIndices.reduce(CGFloat(0)) { $0 + tabHeight($1) + metrics.spacing }
        let lastHeight = count > 0 ? tabHeight(count - 1) : height
        let packedColumn = max(height, usableHeight - metrics.plusZone)

        var mode = Mode.spaced
        var step = spacedStep
        var column: CGFloat
        var bottom = metrics.plusZone

        let spacedHeight = (0..<count).reduce(CGFloat(0)) { $0 + tabHeight($1) } + CGFloat(max(0, count - 1)) * metrics.spacing
        if count <= 1 || spacedHeight <= packedColumn {
            column = count == 0 ? 0 : spacedHeight
        } else {
            let flexible = count - 1 - wholeSteps
            // With nothing flexible there is nothing to give: it scrolls.
            let fitting = flexible > 0
                ? (packedColumn - lastHeight - wholeExtent) / CGFloat(flexible) : 0
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

        // Each tab's top, measured down from the top of the content.
        var tops: [CGFloat] = []
        var running: CGFloat = 0
        for index in 0..<count {
            tops.append(running)
            running += whole.contains(index) ? tabHeight(index) + metrics.spacing : step
        }
        let content = count == 0 ? 0 : (tops.last ?? 0) + lastHeight
        let maxScroll = max(0, content - column)
        let offset = min(maxScroll, max(0, scrollOffset))
        var hovered: Int?
        if let hover, count > 0 {
            let cursor = column - hover.cursorY + offset
            let resting = (0..<count).last { tops[$0] <= cursor && cursor <= tops[$0] + tabHeight($0) }
            if let index = hover.index ?? resting, index < count { hovered = index }
        }

        var frames: [CGRect] = []
        var slices: [CGFloat] = []
        var alphas: [CGFloat] = []
        var hidden = 0
        for index in 0..<count {
            let top = tops[index]
            let height = tabHeight(index)
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
            scrollOffset: offset, maxScrollOffset: maxScroll, hiddenCount: hidden, hovered: hovered,
            lift: metrics.hoverLift
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
        stickyFirst: Bool,
        whole: Set<Int>,
        heights: [Int: CGFloat],
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
        let upperWhole = whole.filter { $0 < above }
        let lowerWhole = Set(whole.filter { $0 >= above + block.count }.map { $0 - above - block.count })
        let upperHeights = heights.filter { $0.key < above }
        let lowerHeights = Dictionary(uniqueKeysWithValues: heights.filter { $0.key >= above + block.count }
            .map { ($0.key - above - block.count, $0.value) })
        func sides(_ room: (upper: CGFloat, lower: CGFloat, shift: CGFloat)) -> (DeckGeometry, DeckGeometry) {
            (layout(count: above, usableHeight: room.upper, columnWidth: columnWidth, scrollOffset: scrollOffset,
                    stickyFirst: stickyFirst, whole: upperWhole, heights: upperHeights, metrics: side),
             layout(count: below, usableHeight: room.lower, columnWidth: columnWidth, scrollOffset: lowerScrollOffset,
                    whole: lowerWhole, heights: lowerHeights, metrics: side))
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

        // The column's origin is the bottom of the lower side (or of the
        // block, without one).
        let bottom = below > 0 ? lowerTop - lower.columnHeight : blockTop - blockHeight
        let topEdge = above > 0 ? upperBase + upper.columnHeight : blockTop
        let zones = metrics.plusZone + (chip ? metrics.overflowZone : 0)
        let extent = min(half, max(topEdge, -(bottom - zones)))
        let columnBottomInMiddle = bottom

        // Everything in the column's coordinates, in the deck's order.
        var frames = upper.frames.map { shifted($0, by: upperBase - columnBottomInMiddle) }
        frames += pinnedFrames(block, blockTop: blockTop - columnBottomInMiddle, width: columnWidth, metrics: metrics)
        frames += lower.frames.map { shifted($0, by: lowerTop - lower.columnHeight - columnBottomInMiddle) }
        let slices = upper.slices + Array(repeating: height, count: block.count) + lower.slices

        // The tab under the cursor is the one the deck at rest shows there
        // (the lowest tab of those overlapping); growing it moves nothing.
        var hovered: Int?
        if let hover {
            var index = hover.index
            if index == nil {
                index = frames.indices.reversed().first { frames[$0].maxY - slices[$0] <= hover.cursorY && hover.cursorY <= frames[$0].maxY }
            }
            if let index, index < count {
                hovered = index
                frames[index].origin.x -= metrics.hoverLift
                frames[index].size.width += metrics.hoverLift
            }
        }

        let deckHeight = 2 * extent
        let columnBottom = columnBottomInMiddle + extent
        let modes = [upper, lower].filter { !$0.frames.isEmpty }.map(\.mode)
        let mode: Mode = modes.contains(.scrolling) ? .scrolling : (modes.contains(.packed) ? .packed : .spaced)
        let steps = [upper, lower].filter { !$0.frames.isEmpty }.map(\.step)
        return DeckGeometry(
            mode: mode,
            step: steps.min() ?? height + gap,
            frames: frames,
            slices: slices,
            alphas: upper.alphas + Array(repeating: 1, count: block.count) + lower.alphas,
            columnHeight: deckHeight - columnBottom,
            columnBottom: columnBottom,
            deckHeight: deckHeight,
            scrollOffset: upper.scrollOffset,
            maxScrollOffset: upper.maxScrollOffset,
            hiddenCount: upper.hiddenCount + lower.hiddenCount,
            hovered: hovered,
            lift: metrics.hoverLift,
            pinned: block,
            chromeBottom: columnBottom - zones,
            upperClip: CGRect(x: 0, y: upperBase - columnBottomInMiddle, width: columnWidth,
                              height: max(0, deckHeight - columnBottom - (upperBase - columnBottomInMiddle))),
            lowerClip: CGRect(x: 0, y: 0, width: columnWidth, height: max(0, lowerTop - columnBottomInMiddle)),
            lowerScrollOffset: lower.scrollOffset,
            lowerMaxScrollOffset: lower.maxScrollOffset,
            stickyHeader: upper.stickyHeader,
            stickyNotesClip: upper.stickyHeader == nil ? .zero
                : shifted(upper.stickyNotesClip, by: upperBase - columnBottomInMiddle)
        )
    }

    /// A side whose first tab is a header that stays: the header on top, a gap,
    /// and the other tabs as an ordinary deck — spaced, packed or scrolling — in
    /// the room that is left.
    private static func stickyLayout(
        count: Int, usableHeight: CGFloat, columnWidth: CGFloat, scrollOffset: CGFloat, hover: Hover?,
        whole: Set<Int>, heights: [Int: CGFloat], metrics: Metrics
    ) -> DeckGeometry {
        let headerHeight = max(metrics.tabHeight, heights[0] ?? metrics.tabHeight)
        let room = headerHeight + metrics.spacing
        let rest = layout(count: count - 1, usableHeight: usableHeight - room, columnWidth: columnWidth,
                          scrollOffset: scrollOffset, whole: Set(whole.filter { $0 > 0 }.map { $0 - 1 }),
                          heights: Dictionary(uniqueKeysWithValues: heights.filter { $0.key > 0 }.map { ($0.key - 1, $0.value) }),
                          metrics: metrics)
        let header = CGRect(x: columnWidth - metrics.tabWidth, y: rest.columnHeight + metrics.spacing,
                            width: metrics.tabWidth, height: headerHeight)
        var geometry = DeckGeometry(
            mode: rest.mode == .scrolling ? .scrolling : .packed,
            step: rest.step,
            frames: [header] + rest.frames,
            slices: [headerHeight] + rest.slices,
            alphas: [1] + rest.alphas,
            columnHeight: rest.columnHeight + room,
            columnBottom: rest.columnBottom,
            deckHeight: rest.deckHeight + room,
            scrollOffset: rest.scrollOffset,
            maxScrollOffset: rest.maxScrollOffset,
            hiddenCount: rest.hiddenCount,
            hovered: nil,
            lift: metrics.hoverLift,
            stickyHeader: 0,
            stickyNotesClip: CGRect(x: 0, y: 0, width: columnWidth, height: rest.columnHeight)
        )
        if let hover {
            let index = hover.index ?? geometry.frames.indices.reversed().first {
                geometry.frames[$0].maxY - geometry.slices[$0] <= hover.cursorY && hover.cursorY <= geometry.frames[$0].maxY
                    && geometry.clip(of: $0).contains(CGPoint(x: columnWidth - 1, y: hover.cursorY))
            }
            if let index, index < count {
                geometry.hovered = index
                geometry.frames[index].origin.x -= metrics.hoverLift
                geometry.frames[index].size.width += metrics.hoverLift
            }
        }
        return geometry
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
}
