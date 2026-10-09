import Foundation

private struct Pin: PinItem {
    var id = UUID()
    var pinnedAt: Date?
}

func runDeckPinsTests() {
    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    expect("pins: five is the limit", String(PinnedDeck.limit), "5")
    expectTrue("pins: four pinned leaves room for one", PinnedDeck.canPin(pinned: 4))
    expectTrue("pins: five pinned leaves none", !PinnedDeck.canPin(pinned: 5))
    expect("pins: the refusal says so", PinnedDeck.limitMessage, "Up to 5 pinned notes")

    let a = Pin(pinnedAt: at(30)), b = Pin(pinnedAt: at(10)), c = Pin(pinnedAt: at(20)), plain = Pin(pinnedAt: nil)
    expect("pins: ranked by when they were pinned",
           PinnedDeck.ranked([a, plain, b, c]).map(\.id).map(\.uuidString).joined(separator: ","),
           [b, c, a].map(\.id.uuidString).joined(separator: ","))
    expect("pins: unpinned notes are left out", String(PinnedDeck.ranked([plain]).count), "0")

    let tied = [Pin(pinnedAt: at(5)), Pin(pinnedAt: at(5))]
    expect("pins: a tie is broken by id, the same on every Mac",
           PinnedDeck.ranked(tied).map(\.id.uuidString).joined(separator: ","),
           tied.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id.uuidString).joined(separator: ","))

    let seven = (0..<7).map { Pin(pinnedAt: at(Double($0))) }
    expect("pins: only the first five count", String(PinnedDeck.ranked(seven).count), "5")
    expect("pins: the later ones are the ones left out",
           PinnedDeck.ranked(seven.reversed()).map(\.id.uuidString).joined(separator: ","),
           seven.prefix(5).map(\.id.uuidString).joined(separator: ","))
}

private struct Tab: PinItem {
    var id = UUID()
    var name: String
    var pinnedAt: Date?
}

func runDeckArrangementTests() {
    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }
    func names(_ tabs: [Tab]) -> String { tabs.map(\.name).joined(separator: " ") }

    // The block for 1…5 pinned notes, named by the order they were pinned.
    let block = (1...5).map { Tab(name: String($0), pinnedAt: at(Double($0))) }
    let expected = ["1", "2 1", "2 1 3", "4 2 1 3", "4 2 1 3 5"]
    for count in 1...5 {
        let arranged = PinnedDeck.arrange(Array(block.prefix(count)))
        expect("arrange: \(count) pinned, top to bottom", names(arranged.items), expected[count - 1])
        expect("arrange: \(count) pinned, the block's size", String(arranged.pinned), String(count))
        expect("arrange: \(count) pinned, nothing else", String(arranged.above) + "/" + String(arranged.below), "0/0")
    }
    expect("arrange: the order does not depend on how they are listed",
           names(PinnedDeck.arrange(block.reversed()).items), "4 2 1 3 5")

    // No pins: the deck as it is.
    let plain = (1...5).map { Tab(name: "p\($0)") }
    let none = PinnedDeck.arrange(plain)
    expect("arrange: nothing pinned leaves the order", names(none.items), "p1 p2 p3 p4 p5")
    expect("arrange: and no block", String(none.pinned), "0")
    expect("arrange: and everything counts as above", String(none.above), "5")
    expect("arrange: an empty deck", String(PinnedDeck.arrange([Tab]()).items.count), "0")

    // Unpinned notes split around the block, in the order they are in.
    let one = Tab(name: "A", pinnedAt: at(1))
    for (others, above, expectedOrder) in [
        (1, 1, "p1 A"), (2, 1, "p1 A p2"), (3, 2, "p1 p2 A p3"), (4, 2, "p1 p2 A p3 p4"), (5, 3, "p1 p2 p3 A p4 p5"),
    ] as [(Int, Int, String)] {
        let arranged = PinnedDeck.arrange(Array(plain.prefix(others)) + [one])
        expect("arrange: \(others) unpinned, above the block", String(arranged.above), String(above))
        expect("arrange: \(others) unpinned, below the block", String(arranged.below), String(others - above))
        expect("arrange: \(others) unpinned, top to bottom", names(arranged.items), expectedOrder)
    }
    // The pinned note can be anywhere in the list it comes from.
    let scattered = [plain[0], plain[1], one, plain[2], plain[3]]
    expect("arrange: the pinned note leaves its place in the list", names(PinnedDeck.arrange(scattered).items), "p1 p2 A p3 p4")

    // Unpinning regroups the rest by the same rule.
    var five = block.map { tab -> Tab in var t = tab; t.name = "k" + t.name; return t }
    five += plain.prefix(4)
    expect("arrange: five pinned and four others", names(PinnedDeck.arrange(five).items), "p1 p2 k4 k2 k1 k3 k5 p3 p4")
    // The first one pinned lets go: the rest are ranked again, the old first
    // pinned now being among the unpinned in the place the list had it.
    five[0].pinnedAt = nil
    expect("arrange: unpinning the first regroups the rest",
           names(PinnedDeck.arrange(five).items), "k1 p1 p2 k5 k3 k2 k4 p3 p4")
    five.removeAll { $0.name == "k1" }
    expect("arrange: without it at all, the same block",
           names(PinnedDeck.arrange(five).items), "p1 p2 k5 k3 k2 k4 p3 p4")

    // More than five pinned (two Macs): the extras read as unpinned.
    let seven = (1...7).map { Tab(name: "s\($0)", pinnedAt: at(Double($0))) }
    let extra = PinnedDeck.arrange(seven)
    expect("arrange: seven pinned, five are in the block", String(extra.pinned), "5")
    expect("arrange: the earliest five", names(Array(extra.items[(extra.above)..<(extra.above + 5)])), "s4 s2 s1 s3 s5")
    expect("arrange: the other two are unpinned, split around it", String(extra.above) + "/" + String(extra.below), "1/1")

    // Applying it to its own result changes nothing, and nothing is lost.
    let mixed = [plain[0], block[2], plain[1], block[0], plain[2], block[4], plain[3], block[1]]
    let once = PinnedDeck.arrange(mixed)
    expect("arrange: nothing is lost", String(Set(once.items.map(\.id)) == Set(mixed.map(\.id))), "true")
    expect("arrange: every note once", String(once.items.count), String(mixed.count))
    expect("arrange: arranging an arranged deck changes nothing", names(PinnedDeck.arrange(once.items).items), names(once.items))
}
