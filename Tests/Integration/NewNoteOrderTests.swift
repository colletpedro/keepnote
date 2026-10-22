import AppKit
import CryptoKit

// MARK: - A new note goes to the end of the stack

@MainActor
func runNewNoteOrderTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("notes.sqlite")
    let store = reopened(database, key: key)

    let first = try! store.create(title: "first")
    let second = try! store.create(title: "second")
    let batch = try! store.create([NoteDraft(title: "third"), NoteDraft(title: "fourth")])
    expect("order: notes follow the order they were made in",
           store.activeNotes.map(\.title).joined(separator: ","), "first,second,third,fourth")
    expectTrue("order: a new note is last", store.activeNotes.last?.id == batch[1].id)
    expectTrue("order: the oldest stays first", store.activeNotes.first?.id == first.id)
    _ = second

    // Archived and moved notes do not change where the next one goes.
    try! store.archive(id: second.id)
    try! store.move(id: first.id, to: 2)
    let fifth = try! store.create(title: "fifth")
    expectTrue("order: after a reorder and an archive, still last", store.activeNotes.last?.id == fifth.id)

    // With notes pinned to the center the new note is the last of the ones
    // under the block, beside the "+", and never inside it.
    try! store.setPinned(true, id: first.id)
    try! store.setPinned(true, id: batch[0].id)
    let sixth = try! store.create(title: "sixth")
    let arrangement = PinnedDeck.arrange(store.activeNotes)
    expectTrue("order: last on the deck with a pinned block", arrangement.items.last?.id == sixth.id)
    expectTrue("order: below the pinned block", arrangement.items.firstIndex { $0.id == sixth.id }! >= arrangement.above + arrangement.pinned)
    expect("order: the block holds the two pinned notes", String(arrangement.pinned), "2")

    // It survives a relaunch.
    store.waitUntilSaved()
    let again = reopened(database, key: key)
    expectTrue("order: still last after reopening", again.activeNotes.last?.id == sixth.id)

    // A note that arrives from another Mac is new here too.
    let arrived = HMNoteFile(id: UUID(), title: "arrived", color: .sky, state: .active, tags: [],
                             createdAt: Date(), updatedAt: Date(), deletedAt: nil, body: "from afar")
    try! again.applyIncoming(arrived.note)
    expectTrue("order: a note from another Mac goes to the end", again.activeNotes.last?.id == arrived.id)

    // The "+", ⌥⌘N and the menu all come through New Note.
    let coordinator = AppCoordinator(store: again)
    let before = Set(again.notes.map(\.id))
    coordinator.menuNewNote()
    let made = again.notes.filter { !before.contains($0.id) }
    expect("order: New Note made one note", String(made.count), "1")
    expectTrue("order: and it is last on the deck", again.activeNotes.last?.id == made.first?.id)
    for window in NSApp.windows.compactMap({ $0 as? NoteWindow }) { window.close() }
}
