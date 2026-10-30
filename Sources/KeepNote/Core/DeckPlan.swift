import CoreGraphics
import Foundation

/// A group as the deck knows it: one of the groups the user made, or Daily.
enum DeckGroupRef: Hashable, Sendable {
    case user(UUID)
    case daily
}

/// One tab of the deck.
enum DeckEntry: Hashable, Sendable {
    case note(UUID)
    /// A group, closed: one tab for all of its notes.
    case group(DeckGroupRef)
    /// A group, open: its header, which the group's own notes follow.
    case header(DeckGroupRef)

    /// Who the tab is, whether or not its group is open: the tab of a group
    /// that opens is the same tab, and keeps its place on screen.
    var key: Key {
        switch self {
        case .note(let id): return .note(id)
        case .group(let ref), .header(let ref): return .group(ref)
        }
    }

    enum Key: Hashable, Sendable {
        case note(UUID)
        case group(DeckGroupRef)
    }

    var noteID: UUID? {
        if case .note(let id) = self { return id }
        return nil
    }

    var groupRef: DeckGroupRef? {
        switch self {
        case .note: return nil
        case .group(let ref), .header(let ref): return ref
        }
    }
}

/// What the plan needs to know about a note. `Note` conforms; the tests use a
/// plain struct.
protocol DeckNote: PinItem {
    var groupID: UUID? { get }
    var isDaily: Bool { get }
}

/// What the deck shows and in what order, from the notes on it, the groups and
/// the group that is open. Foundation only, so all of it is tested directly;
/// `DeckGeometry` then says where each tab goes.
///
/// Top to bottom: the groups, in the order they stand; Daily; the notes in no
/// group. A group the user made is always there, empty or not; a pinned note
/// counts in its group but is not under its header: it is in the pinned block
/// at the centre, as ever.
///
/// An open group takes its tab's place: its header, then its notes. Its notes
/// come first for room. The other tabs stay, packed as tight as the deck packs
/// them, for as long as they fit; those that do not leave, the farthest from
/// the group first. The group itself is never packed: its header and notes stay
/// at the full stage. The header never leaves: if even the group alone does not
/// fit, its notes scroll under it, at full size.
struct DeckPlan: Equatable {
    /// Every tab, top to bottom, the pinned block in its place among them.
    var entries: [DeckEntry]
    var pinned: DeckGeometry.PinnedBlock?
    /// The header stays put while the notes under it scroll
    /// (`DeckGeometry` `stickyFirst`).
    var stickyHeader: Bool
    /// What each group with a tab holds on the deck.
    var counts: [DeckGroupRef: Int]
    /// The group that is open, if the one asked for exists.
    var open: DeckGroupRef?
    /// Tabs that left because the open group needs the room.
    var dropped: Int
    /// How many of the open group's notes follow its header.
    var members: Int = 0
    /// How tall the open group's header is: its name shown whole, where the
    /// name needs more than a note's height.
    var headerHeight: CGFloat = EdgeMetrics.tabHeight

    static let empty = DeckPlan(entries: [], pinned: nil, stickyHeader: false, counts: [:], open: nil, dropped: 0)

    /// What the stack's geometry is made from: it is `layout`'s own inputs.
    func geometry(
        usableHeight: CGFloat, columnWidth: CGFloat, edge: ScreenEdge = .right,
        metrics: DeckGeometry.Metrics = .init()
    ) -> DeckGeometry {
        DeckGeometry.layout(count: entries.count, usableHeight: usableHeight, columnWidth: columnWidth,
                            pinned: pinned, stickyFirst: stickyHeader, whole: wholeIndices, raised: memberIndices, heights: heights,
                            edge: edge,
                            metrics: metrics)
    }

    /// Tabs taller than a note: the open group's header, when its name needs it.
    var heights: [Int: CGFloat] {
        Self.heights(of: entries, headerHeight: headerHeight)
    }

    static func heights(of entries: [DeckEntry], headerHeight: CGFloat) -> [Int: CGFloat] {
        guard headerHeight > EdgeMetrics.tabHeight,
              let header = entries.firstIndex(where: { if case .header = $0 { return true } else { return false } })
        else { return [:] }
        return [header: headerHeight]
    }

    /// The open group's header and its notes among the tabs: they always show
    /// whole, at the full stage, and nothing covers them.
    var wholeIndices: Set<Int> {
        Self.wholeIndices(of: entries, members: members)
    }

    /// The open group's notes, under its header: they stand further out.
    var memberIndices: Set<Int> {
        wholeIndices.filter { if case .note = entries[$0] { return true } else { return false } }
    }

    static func wholeIndices(of entries: [DeckEntry], members: Int) -> Set<Int> {
        guard let header = entries.firstIndex(where: { if case .header = $0 { return true } else { return false } })
        else { return [] }
        return Set(header...min(entries.count - 1, header + members))
    }

    // MARK: - Making the plan

    /// One thing in the order before the pinned block is put in: a group's
    /// tab, an open group's header and notes, or a note.
    private struct Slot {
        var entries: [DeckEntry]
        var isOpenGroup = false
    }

    static func make<T: DeckNote>(
        notes: [T], groups: [NoteGroup], open: DeckGroupRef?,
        usableHeight: CGFloat, columnWidth: CGFloat = 74, headerHeight: CGFloat = EdgeMetrics.tabHeight,
        metrics: DeckGeometry.Metrics = .init()
    ) -> DeckPlan {
        let ranked = PinnedDeck.ranked(notes)
        let inBlock = Set(ranked.map(\.id))
        let blockEntries = PinnedDeck.blockOrder(ranked).map { DeckEntry.note($0.id) }

        // Who is where: a daily in Daily, a note in a group that exists in that
        // group, any other loose. A pinned note is counted in its group but sits
        // in the block, not under the group's header.
        let known = Set(groups.map(\.id))
        var byGroup: [UUID: [T]] = [:]
        var held: [UUID: Int] = [:]
        var daily: [T] = []
        var dailyHeld = 0
        var loose: [T] = []
        for note in notes {
            let pinned = inBlock.contains(note.id)
            if note.isDaily {
                dailyHeld += 1
                if !pinned { daily.append(note) }
            } else if let id = note.groupID, known.contains(id) {
                held[id, default: 0] += 1
                if !pinned { byGroup[id, default: []].append(note) }
            } else if !pinned {
                loose.append(note)
            }
        }

        var counts: [DeckGroupRef: Int] = [:]
        var slots: [Slot] = []
        var openSlot: Int?
        func addGroup(_ ref: DeckGroupRef, _ members: [T], held: Int) {
            counts[ref] = held
            if ref == open {
                openSlot = slots.count
                slots.append(Slot(entries: [.header(ref)] + members.map { .note($0.id) }, isOpenGroup: true))
            } else {
                slots.append(Slot(entries: [.group(ref)]))
            }
        }
        // A group the user made stays on the deck, empty or not; Daily, which
        // nobody makes, is there when it holds a note.
        for group in NoteGroup.sorted(groups) { addGroup(.user(group.id), byGroup[group.id] ?? [], held: held[group.id] ?? 0) }
        if dailyHeld > 0 { addGroup(.daily, daily, held: dailyHeld) }
        for note in loose { slots.append(Slot(entries: [.note(note.id)])) }

        /// The deck for the slots kept: the pinned block put in, not through
        /// the open group when it can be helped.
        func assemble(_ kept: [Int], allAbove: Bool = false) -> (entries: [DeckEntry], pinned: DeckGeometry.PinnedBlock?) {
            var flat: [DeckEntry] = []
            var section: Range<Int>?
            for index in kept {
                let start = flat.count
                flat += slots[index].entries
                if slots[index].isOpenGroup { section = start..<flat.count }
            }
            guard !blockEntries.isEmpty else { return (flat, nil) }
            var above = allAbove ? flat.count : (flat.count + 1) / 2
            if let section, above > section.lowerBound, above < section.upperBound {
                // The group is not cut in two by the block: it goes to
                // whichever end is nearer where the block would have been.
                above = above - section.lowerBound <= section.upperBound - above ? section.lowerBound : section.upperBound
            }
            let entries = Array(flat.prefix(above)) + blockEntries + Array(flat.dropFirst(above))
            return (entries, .init(above: above, count: blockEntries.count))
        }

        var kept = Array(slots.indices)
        var sticky = false
        var droppedEntries = 0
        if let openSlot {
            while true {
                let (entries, pinned) = assemble(kept)
                let whole = wholeIndices(of: entries, members: slots[openSlot].entries.count - 1)
                let g = DeckGeometry.layout(count: entries.count, usableHeight: usableHeight, columnWidth: columnWidth,
                                            pinned: pinned, whole: whole,
                                            heights: heights(of: entries, headerHeight: headerHeight), metrics: metrics)
                if g.mode != .scrolling { break }
                // The group has priority: the tab farthest from it goes; of two
                // as far, the one below, nearer the "+".
                let others = kept.filter { $0 != openSlot }
                guard let farthest = others.max(by: { a, b in
                    let (da, db) = (abs(a - openSlot), abs(b - openSlot))
                    return da != db ? da < db : a < b
                }) else {
                    sticky = true
                    break
                }
                droppedEntries += slots[farthest].entries.count
                kept.removeAll { $0 == farthest }
            }
        }
        let (entries, pinned) = assemble(kept, allAbove: sticky)
        return DeckPlan(entries: entries, pinned: pinned, stickyHeader: sticky, counts: counts,
                        open: openSlot == nil ? nil : open, dropped: droppedEntries,
                        members: openSlot.map { slots[$0].entries.count - 1 } ?? 0,
                        headerHeight: openSlot == nil ? EdgeMetrics.tabHeight : headerHeight)
    }
}
