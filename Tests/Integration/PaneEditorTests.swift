import AppKit
import CryptoKit
import SwiftUI

// MARK: - Editing in All Notes' pane

/// All Notes in a window that is never shown, laid out and given a moment
/// for SwiftUI to build the pane.
@MainActor
func hostAllNotes(_ store: NoteStore, actions: NoteListActions, sidebar: NoteSelection = .library(.all),
                  selecting: Set<UUID>) -> (NSWindow, NSHostingView<AllNotesView>) {
    let view = AllNotesView(store: store, actions: actions, initialSidebar: sidebar, initialSelection: selecting)
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    spin(0.5)
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
}

/// A key pressed in `window`, through the app, so the local monitors see it.
@MainActor
func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in window: NSWindow) {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    else { return }
    NSApp.sendEvent(event)
}

func titleField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.placeholderString == L("Title") { return field }
    return view.subviews.lazy.compactMap(titleField(in:)).first
}

@MainActor
func runPaneEditorTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("pane.sqlite"), key: SymmetricKey(size: .bits256))
    let note = try! store.create(title: "Groceries", body: "- [ ] milk")
    let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                  delete: { _ in }, export: { _ in })
    let (window, hosting) = hostAllNotes(store, actions: actions, selecting: [note.id])

    let body = textView(in: hosting)
    expect("pane: the body is the note's", body?.string, "- [ ] milk")
    expectTrue("pane: the body can be edited", body?.isEditable == true)
    expect("pane: the title is the note's", titleField(in: hosting)?.stringValue, "Groceries")
    expectTrue("pane: the title can be edited", titleField(in: hosting)?.isEnabled == true)

    // Typing saves on its own, as in a note.
    _ = type("\n- [ ] eggs", into: window)
    spin(0.6)
    expect("pane: typing saves by itself", store.note(id: note.id)?.body, "- [ ] milk\n- [ ] eggs")

    // The title too.
    if let field = titleField(in: hosting) {
        window.makeFirstResponder(field)
        (window.firstResponder as? NSTextView)?.insertText(" list", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(0.6)
        expectTrue("pane: the title saves by itself", store.note(id: note.id)?.title.hasSuffix("list") == true)
    }

    // The note's shortcuts work in the pane: ⌘F opens the find bar.
    if let body = textView(in: hosting) { window.makeFirstResponder(body) }
    press(3, "f", .command, in: window)
    hosting.layoutSubtreeIfNeeded()
    spin(0.3)
    let findField = { () -> NSTextField? in
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == L("Find in note") { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(hosting)
    }
    expectTrue("pane: ⌘F opens the find bar", findField() != nil)

    window.close()
}

/// Archived notes and archived dailies are edited in the pane and stay
/// archived; a locked note is shown read-only, with the reason.
@MainActor
func runPaneArchiveTests() {
    let directory = scratchDirectory()
    let url = directory.appendingPathComponent("archived.sqlite")
    let key = SymmetricKey(size: .bits256)
    let store = reopened(url, key: key)
    let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                  delete: { _ in }, export: { _ in })

    let archived = try! store.create(title: "Old", body: "kept")
    try! store.archive(id: archived.id)
    let daily = try! store.create(title: "Daily 01/10", body: "- [ ] call", tags: [DailyNotes.tag])
    try! store.archive(id: daily.id)

    for (name, id, sidebar) in [("archived note", archived.id, NoteSelection.library(.archived)),
                                ("archived daily", daily.id, NoteSelection.library(.daily))] {
        let (window, hosting) = hostAllNotes(store, actions: actions, sidebar: sidebar, selecting: [id])
        expectTrue("pane: an \(name) can be edited", textView(in: hosting)?.isEditable == true)
        _ = type(" more", into: window)
        spin(0.6)
        expectTrue("pane: the \(name)'s edit is saved", store.note(id: id)?.body.hasSuffix(" more") == true)
        expectTrue("pane: and it stays archived", store.note(id: id)?.state == .archived)
        // The rules that archive notes leave it where it is.
        _ = try! store.archiveDailies()
        _ = try! store.archiveStale(days: AutoArchive.defaultDays)
        expectTrue("pane: the \(name) is still archived after the rules run", store.note(id: id)?.state == .archived)
        window.close()
    }
    expectTrue("pane: the archived daily is still a daily", store.note(id: daily.id)?.isDaily == true)

    // A locked note: the key on this Mac cannot open it.
    store.waitUntilSaved()
    let locked = reopened(url, key: SymmetricKey(size: .bits256))
    let id = archived.id
    expectTrue("pane: the note is locked with another key", locked.note(id: id)?.isLocked == true)
    let before = rawBody(url, id: id)!
    let (window, hosting) = hostAllNotes(locked, actions: actions, sidebar: .library(.archived), selecting: [id])
    expectTrue("pane: a locked note's body is read-only", textView(in: hosting)?.isEditable == false)
    expectTrue("pane: a locked note's title is read-only", titleField(in: hosting)?.isEnabled == false)
    _ = type("typed", into: window)
    spin(0.6)
    locked.waitUntilSaved()
    expectTrue("pane: nothing typed reaches the locked note", rawBody(url, id: id)?.ciphertext == before.ciphertext)
    window.close()
}
