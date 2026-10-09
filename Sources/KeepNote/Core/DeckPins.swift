import Foundation

/// What the pinned block needs to know about a note. `Note` conforms; the
/// tests use a plain struct.
protocol PinItem {
    var id: UUID { get }
    var pinnedAt: Date? { get }
}

/// Pin to Center: up to five notes held in a block at the middle of the
/// deck's height, never overlapped. Foundation only, so the rules can be
/// tested without AppKit.
enum PinnedDeck {
    /// How many notes can be pinned at once.
    static let limit = 5

    /// The message shown when a sixth pin is refused.
    static let limitMessage = "Up to \(limit) pinned notes"

    /// Whether one more note can be pinned when `pinned` already are.
    static func canPin(pinned: Int) -> Bool {
        pinned < limit
    }

    /// The pinned notes in the order they were pinned (then by id, so every
    /// Mac agrees), at most `limit` of them: with more than that — two Macs
    /// each pinned one — the later pins are left out and read as unpinned.
    static func ranked<T: PinItem>(_ items: [T]) -> [T] {
        let pinned = items.filter { $0.pinnedAt != nil }
        let ordered = pinned.sorted { a, b in
            a.pinnedAt! != b.pinnedAt! ? a.pinnedAt! < b.pinnedAt! : a.id.uuidString < b.id.uuidString
        }
        return Array(ordered.prefix(limit))
    }
}

// MARK: - Where the tabs go

extension PinnedDeck {
    /// The deck from top to bottom: some unpinned notes, the pinned block,
    /// the rest of the unpinned ones.
    struct Arrangement<T> {
        /// Every note, top to bottom.
        var items: [T]
        /// How many unpinned notes sit above the block.
        var above: Int
        /// How many pinned notes the block holds (none: a plain deck).
        var pinned: Int

        var below: Int { items.count - above - pinned }
    }

    /// The pinned block top to bottom, for notes given in the order they were
    /// pinned. The first goes in the middle, the second above it, the third
    /// below, the fourth above, the fifth below:
    ///
    ///     1 pinned: 1        3 pinned: 2 1 3        5 pinned: 4 2 1 3 5
    ///     2 pinned: 2 1      4 pinned: 4 2 1 3
    ///
    /// With an even number the block is still the thing that is centred, so
    /// the first sits half a tab from the exact middle.
    static func blockOrder<T>(_ ranked: [T]) -> [T] {
        var above: [T] = []   // nearest the middle last
        var below: [T] = []
        for (rank, item) in ranked.enumerated() where rank > 0 {
            if rank % 2 == 1 { above.append(item) } else { below.append(item) }
        }
        return above.reversed() + ranked.prefix(1) + below
    }

    /// Lays out `items`, given in the deck's current order. The pinned notes
    /// leave that order and form the block, by when they were pinned; the
    /// others keep it, the first half (the larger, if odd) above the block and
    /// the rest below. Unpinning one regroups the rest by the same rule, since
    /// the rule only looks at who is pinned now.
    static func arrange<T: PinItem>(_ items: [T]) -> Arrangement<T> {
        let ranked = ranked(items)
        guard !ranked.isEmpty else { return Arrangement(items: items, above: items.count, pinned: 0) }
        let inBlock = Set(ranked.map(\.id))
        let others = items.filter { !inBlock.contains($0.id) }
        let above = (others.count + 1) / 2
        return Arrangement(
            items: Array(others.prefix(above)) + blockOrder(ranked) + Array(others.dropFirst(above)),
            above: above,
            pinned: ranked.count
        )
    }
}
