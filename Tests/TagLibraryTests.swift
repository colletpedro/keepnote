import Foundation

private struct Item: TaggedItem {
    var id = UUID()
    var tags: [String]
    var isArchived = false
    var isDeleted = false
    var isLocked = false
}

func runTagLibraryTests() {
    func list(_ tags: [String]?) -> String { tags.map { $0.joined(separator: ",") } ?? "nil" }
    func entries(_ index: TagLibrary.Index) -> String {
        index.tags.map { "\($0.name)=\($0.count)" }.joined(separator: ",")
    }

    // MARK: Index

    let notes = [
        Item(tags: ["work", "ideas"]),
        Item(tags: ["work"]),
        Item(tags: ["ideas", "área"], isArchived: true),
        Item(tags: ["area"]),
        Item(tags: []),
        Item(tags: [], isArchived: true),
        Item(tags: ["zeta"]),
        Item(tags: ["work", "gone"], isDeleted: true),
        Item(tags: [], isDeleted: true),
    ]
    let index = TagLibrary.index(notes)
    expect("index: most used, then alphabetical; accents fold together",
           entries(index), "area=2,ideas=2,work=2,zeta=1,daily=0")
    expect("index: deleted notes count nowhere", String(index.entry(named: "gone") == nil), "true")
    expect("index: untagged", String(index.untagged), "2")
    expect("index: all", String(index.all), "7")
    expect("index: on the deck", String(index.deck), "5")
    expect("index: archived", String(index.archived), "2")
    expect("index: count(of:)", String(index.count(of: .archived)), "2")
    expect("index: one note with two spellings counts once",
           entries(TagLibrary.index([Item(tags: ["área", "area"])])), "area=1,daily=0")
    expect("index: the spelling most notes use wins",
           entries(TagLibrary.index([Item(tags: ["área"]), Item(tags: ["área"]), Item(tags: ["area"])])), "área=3,daily=0")
    expect("index: entry(named:) ignores case, accents and #", index.entry(named: "#ÁREA")?.name, "area")
    expect("index: empty", entries(TagLibrary.index([Item]())), "daily=0")

    expect("index: the reserved tag is there with no note using it", String(index.entry(named: "#Daily")?.count ?? -1), "0")
    expect("index: used leaves out the reserved tag while no note has it",
           index.used.map(\.name).joined(separator: ","), "area,ideas,work,zeta")
    let withDaily = TagLibrary.index(notes + [Item(tags: ["Daily", "work"]), Item(tags: ["daily"])])
    expect("index: the reserved tag counts its notes and sorts like any tag",
           entries(withDaily), "work=3,area=2,daily=2,ideas=2,zeta=1")
    expect("index: and is then used", withDaily.used.map(\.name).contains("daily") ? "yes" : "no", "yes")

    // MARK: Filter

    func count(_ selection: NoteSelection) -> String { String(TagLibrary.filter(notes, by: selection).count) }
    expect("filter: all", count(.library(.all)), "7")
    expect("filter: on the deck", count(.library(.deck)), "5")
    expect("filter: archived", count(.library(.archived)), "2")
    expect("filter: a tag spans deck and archive", count(.tag("ideas")), "2")
    expect("filter: a tag ignores accents", count(.tag("AREA")), "2")
    expect("filter: a tag only on deleted notes shows nothing", count(.tag("gone")), "0")
    expect("filter: untagged", count(.untagged), "2")
    expect("filter: whole tags only", count(.tag("wor")), "0")

    // MARK: Selection storage

    for selection: NoteSelection in [.library(.all), .library(.deck), .library(.archived), .tag("área/sub"), .untagged] {
        expect("storage round-trips \(selection.storageValue)",
               NoteSelection(storageValue: selection.storageValue)?.storageValue, selection.storageValue)
    }
    expect("storage: garbage is nil", NoteSelection(storageValue: "library:nope")?.storageValue, nil)
    expect("storage: an empty tag is nil", NoteSelection(storageValue: "tag:#")?.storageValue, nil)
    expect("selection titles", [NoteSelection.library(.deck), .tag("work"), .untagged].map(\.title).joined(separator: "|"),
           "On the Deck|#work|Untagged")

    // MARK: One note

    expect("rename in place", list(TagLibrary.renaming("work", to: "job", in: ["a", "work", "b"])), "a,job,b")
    expect("rename: absent tag is nil", list(TagLibrary.renaming("x", to: "y", in: ["a"])), "nil")
    expect("rename: matches ignoring accents", list(TagLibrary.renaming("AREA", to: "place", in: ["área"])), "place")
    expect("rename onto a tag the note has merges at the first position",
           list(TagLibrary.renaming("work", to: "ideas", in: ["work", "a", "ideas"])), "ideas,a")
    expect("rename onto a tag the note has, later spelling", list(TagLibrary.renaming("b", to: "a", in: ["a", "b"])), "a")
    expect("rename merges accent spellings", list(TagLibrary.renaming("x", to: "área", in: ["area", "x"])), "area")
    expect("rename to nothing is nil", list(TagLibrary.renaming("a", to: " # ", in: ["a"])), "nil")
    expect("rename normalises the new name", list(TagLibrary.renaming("a", to: "#New", in: ["a"])), "new")
    expect("remove", list(TagLibrary.removing("b", from: ["a", "b", "c"])), "a,c")
    expect("remove ignores accents and #", list(TagLibrary.removing("#Area", from: ["área", "c"])), "c")
    expect("remove: absent is nil", list(TagLibrary.removing("z", from: ["a"])), "nil")
    expect("add at the end", list(TagLibrary.adding("#New", to: ["a"])), "a,new")
    expect("add: already there is nil", list(TagLibrary.adding("ÁREA", to: ["área"])), "nil")
    expect("add: not a tag is nil", list(TagLibrary.adding("#", to: ["a"])), "nil")

    // MARK: Many notes

    let locked = Item(tags: ["work", "x"], isLocked: true)
    let a = Item(tags: ["work", "ideas"])
    let b = Item(tags: ["ideas"])
    let c = Item(tags: ["work"], isDeleted: true)
    let pool = [locked, a, b, c]

    let rename = TagLibrary.rename("work", to: "Ideas", in: pool)
    expect("rename onto an existing tag says it merges", rename.map { "\($0.target) \($0.merges)" }, "ideas true")
    expect("rename to a new name does not merge", TagLibrary.rename("work", to: "job", in: pool).map { "\($0.target) \($0.merges)" }, "job false")
    expect("rename onto an existing tag takes its spelling",
           TagLibrary.rename("ideas", to: "AREA", in: [Item(tags: ["ideas"]), Item(tags: ["área"])])?.target, "área")
    expect("rename to the same name is nil", TagLibrary.rename("work", to: "#WORK", in: pool)?.target, nil)
    expect("rename that only fixes accents keeps the new spelling",
           TagLibrary.rename("area", to: "área", in: [Item(tags: ["area"])]).map { "\($0.target) \($0.merges)" }, "área false")
    expect("rename to an empty name is nil", TagLibrary.rename("work", to: "", in: pool)?.target, nil)

    let renamePlan = TagLibrary.renamePlan("work", to: "ideas", in: pool)
    expect("rename plan: only unlocked, live notes with the tag", String(renamePlan.changes.count), "1")
    expect("rename plan: merged tags", list(renamePlan.changes[a.id]), "ideas")
    expect("rename plan: locked notes are skipped and counted", String(renamePlan.skippedLocked), "1")
    expect("rename plan: no-op rename changes nothing", String(TagLibrary.renamePlan("work", to: "work", in: pool).changes.count), "0")

    let deletePlan = TagLibrary.deletePlan("ideas", in: pool)
    expect("delete plan: every live note with it", String(deletePlan.changes.count), "2")
    expect("delete plan: the note stays, without the tag", list(deletePlan.changes[b.id]), "")
    expect("delete plan: other tags stay", list(deletePlan.changes[a.id]), "work")
    expect("delete plan: nothing locked had it", String(deletePlan.skippedLocked), "0")
    expect("delete plan: a locked note with it is counted", String(TagLibrary.deletePlan("work", in: pool).skippedLocked), "1")

    let addPlan = TagLibrary.addPlan("ideas", to: [a, b, Item(tags: [])])
    expect("add plan: skips notes that have it", String(addPlan.changes.count), "1")
    let removePlan = TagLibrary.removePlan("work", from: [locked, a, b])
    expect("remove plan: changes the ones that have it", String(removePlan.changes.count), "1")
    expect("remove plan: counts locked", String(removePlan.skippedLocked), "1")

    // MARK: Messages

    expect("delete message, plural", TagLibrary.deleteMessage("work", count: 3).detail,
           "3 notes will lose this tag. The notes themselves are kept.")
    expect("delete message, one", TagLibrary.deleteMessage("work", count: 1).detail,
           "1 note will lose this tag. The notes themselves are kept.")
    expect("delete title", TagLibrary.deleteMessage("work", count: 1).title, "Delete the tag \u{201C}#work\u{201D}?")
    expect("merge title", TagLibrary.mergeMessage("work", into: "ideas", count: 2).title,
           "Merge \u{201C}#work\u{201D} into \u{201C}#ideas\u{201D}?")
    expectTrue("merge detail says it exists and counts",
               TagLibrary.mergeMessage("work", into: "ideas", count: 2).detail.contains("already exists. 2 notes tagged #work"))

    // MARK: Drag payload

    let ids = [UUID(), UUID()]
    expectTrue("drag payload round-trips", NoteDragPayload.decode(NoteDragPayload.encode(ids)) == ids)
    expect("drag payload: plain text is ignored", String(NoteDragPayload.decode("hello").count), "0")
    expect("drag payload: bad ids are skipped",
           String(NoteDragPayload.decode(NoteDragPayload.prefix + "nope," + ids[0].uuidString).count), "1")
    expect("drag payload: repeats once", String(NoteDragPayload.decode(NoteDragPayload.encode([ids[0], ids[0]])).count), "1")
    expect("drag payload: empty", String(NoteDragPayload.decode(NoteDragPayload.encode([])).count), "0")
}
