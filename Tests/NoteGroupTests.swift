import Foundation

/// A plain note for the group rules.
private struct Item: GroupedItem {
    var id = UUID()
    var groupID: UUID?
    var isArchived = false
    var isDeleted = false
}

func runNoteGroupTests() {
    // MARK: Names

    expect("name: trimmed", NoteGroup.cleaned("  Work  "), "Work")
    expect("name: on one line", NoteGroup.cleaned("Work\nand more"), "Work and more")
    expectTrue("name: nothing is not a name", NoteGroup.cleaned("   \n ") == nil)
    expectTrue("name: nor is the empty string", NoteGroup.cleaned("") == nil)
    expect("name: cut to the limit", String(NoteGroup.cleaned(String(repeating: "a", count: 200))!.count), String(NoteGroup.nameLimit))
    expect("name: accents and emoji survive", NoteGroup.cleaned("Trabalho ação 📌"), "Trabalho ação 📌")

    // MARK: Order

    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let a = NoteGroup(name: "A", order: 1, createdAt: t0)
    let b = NoteGroup(name: "B", order: 0, createdAt: t0.addingTimeInterval(5))
    let c = NoteGroup(name: "C", order: 1, createdAt: t0.addingTimeInterval(-5))
    expect("order: by order, then when made", NoteGroup.sorted([a, b, c]).map(\.name).joined(), "BCA")
    var d = NoteGroup(name: "D", order: 1, createdAt: t0)
    d.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var e = a
    e.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    e.name = "E"
    expect("order: then by id, so every Mac agrees", NoteGroup.sorted([e, d]).map(\.name).joined(), "DE")
    expect("order: the same whichever way they come", NoteGroup.sorted([d, e]).map(\.name).joined(), "DE")

    expect("reorder: the named first, in that order", NoteGroup.reordered([a, b, c], ids: [a.id, b.id]).map(\.name).joined(), "ABC")
    expect("reorder: those not named follow", NoteGroup.reordered([a, b, c], ids: [c.id]).map(\.name).joined(), "CBA")
    expect("reorder: an unknown id is ignored", NoteGroup.reordered([a, b], ids: [UUID(), b.id]).map(\.name).joined(), "BA")
    expect("reorder: and so is a repeat", NoteGroup.reordered([a, b], ids: [b.id, b.id, a.id]).map(\.name).joined(), "BA")

    // MARK: Last writer wins

    var newer = a
    newer.updatedAt = a.updatedAt.addingTimeInterval(1)
    expectTrue("accepts: a newer copy", a.accepts(newer))
    expectTrue("accepts: not the same one again", !a.accepts(a))
    expectTrue("accepts: nor an older one", !newer.accepts(a))

    // MARK: Who is in what

    let work = NoteGroup(name: "Work")
    let home = NoteGroup(name: "Home")
    let gone = UUID()
    let items = [
        Item(groupID: work.id), Item(groupID: work.id, isArchived: true), Item(groupID: home.id),
        Item(groupID: nil), Item(groupID: gone), Item(groupID: work.id, isDeleted: true),
    ]
    let counts = GroupLibrary.counts(items, groups: [work, home])
    expect("counts: work, archived included, deleted not", String(counts.count(of: work.id)), "2")
    expect("counts: home", String(counts.count(of: home.id)), "1")
    expect("counts: no group, and one naming a group that is not here", String(counts.ungrouped), "2")
    expect("counts: a group nobody is in", String(counts.count(of: UUID())), "0")
    expectTrue("effective: a known group", GroupLibrary.effectiveGroup(of: items[0], among: [work, home]) == work.id)
    expectTrue("effective: an unknown one is none", GroupLibrary.effectiveGroup(of: items[4], among: [work, home]) == nil)
    expectTrue("effective: none is none", GroupLibrary.effectiveGroup(of: items[3], among: [work, home]) == nil)
    expect("members: of work, in the order given", String(GroupLibrary.members(of: work.id, in: items, groups: [work, home]).count), "2")
    expect("members: of a group that does not exist", String(GroupLibrary.members(of: gone, in: items, groups: [work]).count), "0")
    expect("ungrouped: the two", String(GroupLibrary.ungrouped(items, groups: [work, home]).count), "2")
    expect("ungrouped: with the group gone from here, its note is loose",
           String(GroupLibrary.ungrouped(items, groups: [home]).count), "4")
}
