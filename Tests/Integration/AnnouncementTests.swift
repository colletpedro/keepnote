import AppKit
import CryptoKit

/// What VoiceOver is told when something changes away from its cursor.
@MainActor
func runAnnouncementTests() {
    final class Clock { var date = Date() }
    let clock = Clock()
    let url = scratchDirectory().appendingPathComponent("announce-\(UUID().uuidString).sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)), now: { clock.date })
    let coordinator = AppCoordinator(store: store)

    coordinator.newNote()
    expect("say: a new note", Announcer.last, "New note")
    let note = store.notes.first!
    NSApp.windows.compactMap { $0 as? NoteWindow }.forEach { $0.orderOut(nil) }
    coordinator.setPinned(true, ids: [note.id])
    expect("say: pinned", Announcer.last, "Pinned to center")
    coordinator.setPinned(false, ids: [note.id])
    expect("say: unpinned", Announcer.last, "Unpinned from center")
    coordinator.archive(ids: [note.id])
    expect("say: archived", Announcer.last, "Note archived")
    coordinator.unarchive(ids: [note.id])
    expect("say: back on the deck", Announcer.last, "Note back on the deck")
    coordinator.delete(ids: [note.id])
    expect("say: deleted, and where Undo is", Announcer.last, "Note deleted. Undo is in the notice at the bottom of the screen.")
    coordinator.undoToastForTesting.undoForTesting?()

    // The time rule, as at launch: a note not opened for longer than the setting.
    let old = try! store.create(title: "Old", body: "")
    clock.date = Date().addingTimeInterval(86_400 * 40)
    coordinator.runArchiveRules()
    expect("say: archived by the time rule", Announcer.last, "1 note was archived automatically")
    expect("say: and it was", store.note(id: old.id)?.state.rawValue, "archived")
}
