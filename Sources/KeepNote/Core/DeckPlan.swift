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
/// group. A group that has nothing on the deck is not there, and a pinned note
/// is not in its group: it is in the pinned block at the centre, as ever.
///
/// An open group takes its tab's place: its header, then its notes. Its notes
/// come first for room. The other tabs stay, packed as tight as the deck packs
/// them, for as long as they fit; those that do not leave, the farthest from
/// the group first. The header never leaves: if even the group alone does not
/// fit, its notes scroll under it.
struct DeckPlan: Equatable {
    /// Every tab, top to bottom, the pinned block in its place among them.
    var entries: [DeckEntry]
    var pinned: DeckGeometry.PinnedBlock?
    /// The header stays put while the notes under it scroll
    /// (`DeckGeometry` `stickyFirst`).
    var stickyHeader: Bool
    /// What each group with a tab holds on the deck.
    var counts: [DeckGroupRef: Int]
    /// The group that is open, if the one asked for exists and has notes.
    var open: DeckGroupRef?
    /// Tabs that left because the open group needs the room.
    var dropped: Int

    static let empty = DeckPlan(entries: [], pinned: nil, stickyHeader: false, counts: [:], open: nil, dropped: 0)

    /// What the stack's geometry is made from: it is `layout`'s own inputs.
    func geometry(
        usableHeight: CGFloat, columnWidth: CGFloat, edge: ScreenEdge = .right,
        metrics: DeckGeometry.Metrics = .init()
    ) -> DeckGeometry {
        DeckGeometry.layout(count: entries.count, usableHeight: usableHeight, columnWidth: columnWidth,
                            pinned: pinned, stickyFirst: stickyHeader, edge: edge, metrics: metrics)
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
        usableHeight: CGFloat, columnWidth: CGFloat = 74, metrics: DeckGeometry.Metrics = .init()
    ) -> DeckPlan {
        let ranked = PinnedDeck.ranked(notes)
        let inBlock = Set(ranked.map(\.id))
        let blockEntries = PinnedDeck.blockOrder(ranked).map { DeckEntry.note($0.id) }

        // Who is where: a pinned note is in the block, a daily in Daily, a
        // note in a group that exists in that group, any other loose.
        let known = Set(groups.map(\.id))
        var byGroup: [UUID: [T]] = [:]
        var daily: [T] = []
        var loose: [T] = []
        for note in notes where !inBlock.contains(note.id) {
            if note.isDaily {
                daily.append(note)
            } else if let id = note.groupID, known.contains(id) {
                byGroup[id, default: []].append(note)
            } else {
                loose.append(note)
            }
        }

        var counts: [DeckGroupRef: Int] = [:]
        var slots: [Slot] = []
        var openSlot: Int?
        func addGroup(_ ref: DeckGroupRef, _ members: [T]) {
            guard !members.isEmpty else { return }
            counts[ref] = members.count
            if ref == open {
                openSlot = slots.count
                slots.append(Slot(entries: [.header(ref)] + members.map { .note($0.id) }, isOpenGroup: true))
            } else {
                slots.append(Slot(entries: [.group(ref)]))
            }
        }
        for group in NoteGroup.sorted(groups) { addGroup(.user(group.id), byGroup[group.id] ?? []) }
        addGroup(.daily, daily)
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
                let g = DeckGeometry.layout(count: entries.count, usableHeight: usableHeight, columnWidth: columnWidth,
                                            pinned: pinned, metrics: metrics)
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
                        open: openSlot == nil ? nil : open, dropped: droppedEntries)
    }
}
