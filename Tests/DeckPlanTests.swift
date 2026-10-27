import CoreGraphics
import Foundation

private struct N: DeckNote {
    var id = UUID()
    var pinnedAt: Date?
    var groupID: UUID?
    var isDaily = false
}

func runDeckPlanTests() {
    func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let work = NoteGroup(name: "Work", order: 0, createdAt: t0)
    let home = NoteGroup(name: "Home", order: 1, createdAt: t0)
    let empty = NoteGroup(name: "Empty", order: 2, createdAt: t0)
    func plan(_ notes: [N], groups: [NoteGroup], open: DeckGroupRef? = nil, height: CGFloat = 926) -> DeckPlan {
        DeckPlan.make(notes: notes, groups: groups, open: open, usableHeight: height)
    }
    func names(_ plan: DeckPlan, _ notes: [N], groups: [NoteGroup]) -> String {
        plan.entries.map { entry -> String in
            switch entry {
            case .note(let id): return "n\(notes.firstIndex { $0.id == id }.map(String.init) ?? "?")"
            case .group(.daily): return "[Daily]"
            case .header(.daily): return "<Daily>"
            case .group(.user(let id)): return "[\(groups.first { $0.id == id }?.name ?? "?")]"
            case .header(.user(let id)): return "<\(groups.first { $0.id == id }?.name ?? "?")>"
            }
        }.joined(separator: " ")
    }

    // MARK: Without groups it is the deck it was

    let loose = (0..<5).map { _ in N() }
    let plain = plan(loose, groups: [])
    expect("plan: no groups, the notes in their order", names(plain, loose, groups: []), "n0 n1 n2 n3 n4")
    expectTrue("plan: no block, nothing open, nothing dropped", plain.pinned == nil && plain.open == nil && plain.dropped == 0 && !plain.stickyHeader)
    var pinnedLoose = (0..<6).map { _ in N() }
    pinnedLoose[2].pinnedAt = t0
    let arranged = PinnedDeck.arrange(pinnedLoose)
    let withBlock = plan(pinnedLoose, groups: [])
    expectTrue("plan: with a pinned block it is PinnedDeck's own arrangement",
               withBlock.entries == arranged.items.map { .note($0.id) }
               && withBlock.pinned == .init(above: arranged.above, count: arranged.pinned))

    // MARK: Groups, Daily, then the rest

    var notes = (0..<10).map { _ in N() }
    notes[1].groupID = home.id
    notes[2].groupID = work.id
    notes[4].groupID = work.id
    notes[5].isDaily = true
    notes[6].isDaily = true
    notes[8].groupID = UUID()   // a group this Mac does not have
    let all = [work, home, empty]
    let closed = plan(notes, groups: all)
    expect("order: groups in the order they stand, Daily, then the loose notes",
           names(closed, notes, groups: all), "[Work] [Home] [Daily] n0 n3 n7 n8 n9")
    expect("counts: what each group holds", [closed.counts[.user(work.id)], closed.counts[.user(home.id)], closed.counts[.daily]]
        .map { String($0 ?? -1) }.joined(separator: ","), "2,1,2")
    expectTrue("counts: a group with nothing on the deck has no tab", closed.counts[.user(empty.id)] == nil)
    let reordered = NoteGroup(id: home.id, name: "Home", order: -1, createdAt: t0)
    expectTrue("order: moving a group moves its tab",
               names(plan(notes, groups: [work, reordered]), notes, groups: [work, reordered]).hasPrefix("[Home] [Work] [Daily]"))

    // A note pinned to the center is in the block, not in its group.
    var pinnedMember = notes
    pinnedMember[2].pinnedAt = t0
    let pinnedPlan = plan(pinnedMember, groups: all)
    expectTrue("pinned: a pinned member is in the block", pinnedPlan.entries.contains(.note(pinnedMember[2].id)) && pinnedPlan.pinned?.count == 1)
    expect("pinned: and the group counts what is left", String(pinnedPlan.counts[.user(work.id)] ?? -1), "1")
    var onlyPinned = notes
    onlyPinned[2].pinnedAt = t0
    onlyPinned[4].pinnedAt = t0.addingTimeInterval(1)
    expectTrue("pinned: a group whose notes are all pinned has no tab", plan(onlyPinned, groups: all).counts[.user(work.id)] == nil)
    var pinnedDaily = notes
    pinnedDaily[5].pinnedAt = t0
    expect("pinned: a pinned daily is in the block; Daily holds the other", String(plan(pinnedDaily, groups: all).counts[.daily] ?? -1), "1")
    var noDailies = notes
    noDailies[5].isDaily = false
    noDailies[6].isDaily = false
    expectTrue("daily: no dailies, no Daily", plan(noDailies, groups: all).counts[.daily] == nil
               && !plan(noDailies, groups: all).entries.contains(.group(.daily)))

    // MARK: Open

    let opened = plan(notes, groups: all, open: .user(work.id))
    expect("open: the header takes the tab's place and its notes follow",
           names(opened, notes, groups: all), "<Work> n2 n4 [Home] [Daily] n0 n3 n7 n8 n9")
    expectTrue("open: the group is open", opened.open == .user(work.id))
    expectTrue("open: it all fits, so nothing left", opened.dropped == 0 && !opened.stickyHeader)
    let dailyOpen = plan(notes, groups: all, open: .daily)
    expectTrue("open: Daily opens like any group", dailyOpen.entries.contains(.header(.daily)) && dailyOpen.open == .daily
               && dailyOpen.entries.contains(.note(notes[5].id)) && dailyOpen.entries.contains(.note(notes[6].id)))
    expectTrue("open: a group that has nothing is not open", plan(notes, groups: all, open: .user(empty.id)).open == nil)
    expectTrue("open: nor one that does not exist", plan(notes, groups: all, open: .user(UUID())).open == nil)
    expectTrue("open: the tab and the header are the same tab",
               DeckEntry.group(.user(work.id)).key == DeckEntry.header(.user(work.id)).key)

    // MARK: Not enough room: the group first

    func crowded(group: Int, others: Int, groupOf: UUID, extraGroups: Int = 0) -> ([N], [NoteGroup]) {
        var list: [N] = []
        var extra: [NoteGroup] = []
        for index in 0..<extraGroups {
            let g = NoteGroup(name: "G\(index)", order: 10 + index, createdAt: t0)
            extra.append(g)
            list.append(N(groupID: g.id))
        }
        list += (0..<group).map { _ in N(groupID: groupOf) }
        list += (0..<others).map { _ in N() }
        return (list, extra)
    }
    let (many, extraGroups) = crowded(group: 6, others: 80, groupOf: work.id, extraGroups: 2)
    let groupsMany = [work] + extraGroups
    let tight = plan(many, groups: groupsMany, open: .user(work.id), height: 700)
    expectTrue("crowded: the header is there", tight.entries.contains(.header(.user(work.id))))
    expectTrue("crowded: every note of the group is there",
               many.filter { $0.groupID == work.id }.allSatisfy { tight.entries.contains(.note($0.id)) })
    expectTrue("crowded: others left, so the deck does not scroll",
               tight.dropped > 0 && tight.geometry(usableHeight: 700, columnWidth: 74).mode != .scrolling)
    expect("crowded: the entries are what is left", String(tight.entries.count), String(1 + 6 + 2 + 80 - tight.dropped))
    // They are kept packed as tight as the deck packs them.
    let g = tight.geometry(usableHeight: 700, columnWidth: 74)
    expectTrue("crowded: down to the minimum slice, no further", g.step >= EdgeMetrics.minimumVisibleSlice - 0.001)
    expectTrue("crowded: and as many as that holds", {
        let one = DeckPlan(entries: tight.entries + [.note(UUID())], pinned: nil, stickyHeader: false, counts: [:], open: nil, dropped: 0)
        return one.geometry(usableHeight: 700, columnWidth: 74).mode == .scrolling
    }())
    // The ones that stay are the nearest to the group.
    let keptNotes = many.indices.filter { tight.entries.contains(.note(many[$0].id)) }
    let groupRange = many.indices.filter { many[$0].groupID == work.id }
    let lastNear = (keptNotes.filter { many[$0].groupID == nil }).min() ?? -1
    expectTrue("crowded: those nearest the group stay, the ones at the foot of the deck go",
               lastNear == groupRange.last! + 1 && !tight.entries.contains(.note(many.last!.id)))

    // Of two as far away, the one below goes.
    let (pair, pairGroups) = crowded(group: 20, others: 0, groupOf: work.id, extraGroups: 0)
    var twoEither = pair
    let above = N(groupID: home.id)
    twoEither.insert(above, at: 0)
    let below = N()
    twoEither.append(below)
    // Make them the only others: tiny screen so exactly one fits beside the group.
    var verdict: [String] = []
    for height in stride(from: 380, through: 700, by: 10) {
        let p = DeckPlan.make(notes: twoEither, groups: [work, home], open: .user(work.id), usableHeight: CGFloat(height))
        let keptAbove = p.entries.contains(.group(.user(home.id)))
        let keptBelow = p.entries.contains(.note(below.id))
        if keptBelow && !keptAbove { verdict.append("\(height)") }
    }
    _ = pairGroups
    expect("crowded: equally far, the tab below goes before the one above \(verdict)", verdict.joined(), "")

    // MARK: The header never leaves

    let big = (0..<60).map { _ in N(groupID: work.id) } + (0..<10).map { _ in N() }
    var leaves: [String] = []
    var offscreen: [String] = []
    var everyNote: [String] = []
    var fitsScreen: [String] = []
    var steady: [String] = []
    for height in [300, 420, 560, 700, 926, 1300] as [CGFloat] {
        for size in [1, 4, 12, 30, 60] {
            for others in [0, 3, 10] {
                for pinnedCount in [0, 1, 3, 5] {
                    for edge in [ScreenEdge.right, .left] {
                        var list = Array(big.prefix(size)) + Array(big.suffix(10).prefix(others))
                        for index in 0..<pinnedCount where list.count > size + index { list[size + index].pinnedAt = t0.addingTimeInterval(Double(index)) }
                        let p = DeckPlan.make(notes: list, groups: [work], open: .user(work.id), usableHeight: height)
                        let label = "\(Int(height))/\(size)/\(others)/\(pinnedCount)/\(edge)"
                        guard let headerAt = p.entries.firstIndex(of: .header(.user(work.id))) else { leaves.append(label); continue }
                        if !list.filter({ $0.groupID == work.id }).allSatisfy({ p.entries.contains(.note($0.id)) }) { everyNote.append(label) }
                        let geometry = p.geometry(usableHeight: height, columnWidth: 74, edge: edge)
                        if geometry.deckHeight > height + 0.01 { fitsScreen.append(label) }
                        // A screen too short for the block, a whole tab on each side and the
                        // foot of the column cannot show everything, as in the pinned tests.
                        let needed = CGFloat(pinnedCount) * (EdgeMetrics.tabHeight + EdgeMetrics.tabSpacing)
                            + 3 * (EdgeMetrics.tabHeight + EdgeMetrics.tabSpacing)   // the header, a note, and one more side
                            + EdgeMetrics.plusTopMargin + EdgeMetrics.plusDiameter + EdgeMetrics.overflowHeight + EdgeMetrics.tabSpacing
                        guard pinnedCount == 0 || needed <= height else { continue }
                        for offset in [0, 50, 99_999] as [CGFloat] {
                            for lowerOffset in [0, 99_999] as [CGFloat] {
                                let g = DeckGeometry.layout(
                                    count: p.entries.count, usableHeight: height, columnWidth: 74, scrollOffset: offset,
                                    lowerScrollOffset: lowerOffset, pinned: p.pinned, stickyFirst: p.stickyHeader,
                                    headers: p.headerIndices, edge: edge)
                                let frame = g.frames[headerAt]
                                // Whole and in the column, at every stage: nothing covers it.
                                if g.alphas[headerAt] < 0.999 || frame.minY < -0.01 || frame.maxY > g.columnHeight + 0.01
                                    || g.slices[headerAt] < EdgeMetrics.tabHeight - 0.01 { offscreen.append(label + " scroll \(offset)") }
                                // And the notes scrolling under it never cover it: at the end of a
                                // sticky deck, what shows of them is below it.
                                if p.stickyHeader, !g.clip(of: headerAt + 1).isNull, g.clip(of: headerAt + 1).maxY > frame.minY + 0.01 {
                                    steady.append(label + " clip")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    expectTrue("header: always on the deck \(leaves.prefix(3))", leaves.isEmpty)
    expectTrue("header: with every note of its group, however many \(everyNote.prefix(3))", everyNote.isEmpty)
    expectTrue("header: the deck never runs past the screen, either edge \(fitsScreen.prefix(3))", fitsScreen.isEmpty)
    expectTrue("header: in the column, in view, however the deck is scrolled, either edge \(offscreen.prefix(3))", offscreen.isEmpty)
    expectTrue("header: the notes that scroll are clipped under it \(steady.prefix(3))", steady.isEmpty)

    // A small screen and a big group, packed: the header is whole and only the notes under it give way.
    let packedPlan = DeckPlan.make(notes: Array(big.prefix(8)), groups: [work], open: .user(work.id), usableHeight: 520)
    for edge in [ScreenEdge.right, .left] {
        let g = packedPlan.geometry(usableHeight: 520, columnWidth: 74, edge: edge)
        let at = packedPlan.entries.firstIndex(of: .header(.user(work.id))) ?? 0
        expectTrue("header: packed deck, either edge — it is a deck that packs", g.mode == .packed)
        expect("header: packed deck, whole slice (\(edge))", f(g.slices[at]), f(EdgeMetrics.tabHeight))
        expectTrue("header: packed deck, the first note starts below it (\(edge))",
                   g.frames[at + 1].maxY <= g.frames[at].minY + 0.01)
        expectTrue("header: packed deck, the notes under it are the ones that overlap (\(edge))",
                   g.slices[at + 1] < EdgeMetrics.tabHeight)
    }

    // A group too big for the screen: the others are gone, the header stays and the notes scroll.
    let huge = (0..<80).map { _ in N(groupID: work.id) } + (0..<6).map { _ in N() }
    let sticky = plan(huge, groups: [work], open: .user(work.id), height: 700)
    expectTrue("sticky: a group that does not fit alone is sticky", sticky.stickyHeader)
    expectTrue("sticky: the others are all gone", sticky.entries.count == 81 && sticky.dropped == 6)
    expectTrue("sticky: the header is the first tab", sticky.entries.first == .header(.user(work.id)))
    let rest = sticky.geometry(usableHeight: 700, columnWidth: 74)
    expectTrue("sticky: the notes under it scroll", rest.mode == .scrolling && rest.maxScrollOffset > 0)
    let scrolled = DeckGeometry.layout(count: sticky.entries.count, usableHeight: 700, columnWidth: 74, scrollOffset: 400,
                                       stickyFirst: true)
    expect("sticky: the header does not move when they do", f(scrolled.frames[0].minY), f(rest.frames[0].minY))
    expect("sticky: and is at the top of the column", f(rest.frames[0].maxY), f(rest.columnHeight))
    expectTrue("sticky: the notes do move", scrolled.frames[1] != rest.frames[1])
    expectTrue("sticky: and are clipped under the header", scrolled.clip(of: 1).maxY <= rest.frames[0].minY + 0.01)
    expectTrue("sticky: the header is seen over the whole column", rest.clip(of: 0).height == rest.columnHeight)
    // Hover and hit-testing know the header.
    let hit = scrolled.tab(at: CGPoint(x: 60, y: scrolled.frames[0].midY))
    expectTrue("sticky: the header is under the cursor over it", hit == 0)
    let hovered = DeckGeometry.layout(count: sticky.entries.count, usableHeight: 700, columnWidth: 74, scrollOffset: 400,
                                      hover: .init(index: 0, cursorY: 0), stickyFirst: true)
    expectTrue("sticky: it reaches out like any tab", hovered.hovered == 0 && hovered.frames[0].width == EdgeMetrics.tabWidth + EdgeMetrics.hoverLift)
    // A group that fits is no different from any other tab.
    let fits = DeckGeometry.layout(count: 6, usableHeight: 926, columnWidth: 74, stickyFirst: true)
    expectTrue("sticky: asked for but not needed, the deck is as it is", fits == DeckGeometry.layout(count: 6, usableHeight: 926, columnWidth: 74))

    // MARK: The block and an open group

    var around = (0..<12).map { _ in N() }
    for index in 3..<9 { around[index].groupID = work.id }
    around[10].pinnedAt = t0
    around[11].pinnedAt = t0.addingTimeInterval(1)
    let block = plan(around, groups: [work], open: .user(work.id))
    expectTrue("block: two pinned notes in the block", block.pinned?.count == 2)
    let headerIndex = block.entries.firstIndex(of: .header(.user(work.id)))!
    let lastNote = block.entries.lastIndex(of: .note(around[8].id))!
    let blockStart = block.pinned!.above
    expectTrue("block: the group is not cut in two by it", blockStart <= headerIndex || blockStart > lastNote)
    expectTrue("block: its notes follow its header", (headerIndex...lastNote).count == 7
               && (headerIndex + 1...lastNote).allSatisfy { block.entries[$0].noteID != nil })
}
