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

/// Selecting a note in All Notes is opening it, for the time rule.
@MainActor
func runPaneOpenedTests() {
    final class Clock { var date = Date() }
    let clock = Clock()
    clock.date = Date(timeIntervalSince1970: 1_790_000_000)
    let url = scratchDirectory().appendingPathComponent("opened.sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)), now: { clock.date })
    let coordinator = AppCoordinator(store: store)
    let note = try! store.create(title: "Quiet", body: "x")
    let other = try! store.create(title: "Other", body: "y")
    let days = AutoArchive.defaultDays

    // The view says which note the pane shows.
    var selected: [UUID?] = []
    var actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                  delete: { _ in }, export: { _ in })
    actions.select = { selected.append($0) }
    let (window, _) = hostAllNotes(store, actions: actions, selecting: [note.id])
    expectTrue("opened: the pane reports the note it shows", selected.last == .some(note.id))
    window.close()

    // Weeks later the note is selected: it counts as opened today.
    clock.date = clock.date.addingTimeInterval(Double(days + 5) * 86_400)
    coordinator.allNotesDidSelect(note.id)
    expect("opened: selecting it opens it today", store.note(id: note.id)?.lastOpenedDay?.string, store.today.string)
    coordinator.runArchiveRules()
    expectTrue("opened: so the rule leaves it on the deck", store.note(id: note.id)?.state == .active)
    expectTrue("opened: the note nobody selected is archived", store.note(id: other.id)?.state == .archived)

    // While it stays selected, the days going by do not archive it.
    clock.date = clock.date.addingTimeInterval(Double(days + 5) * 86_400)
    coordinator.runArchiveRules()
    expectTrue("opened: while it is in the pane it is not archived", store.note(id: note.id)?.state == .active)

    // Selecting another one: the first counts as used until now.
    let third = try! store.create(title: "Third", body: "z")
    coordinator.allNotesDidSelect(third.id)
    expect("opened: leaving the pane counts as its last opening", store.note(id: note.id)?.lastOpenedDay?.string, store.today.string)
    coordinator.allNotesDidSelect(nil)
}

/// Open in All Notes opens the note floating.
@MainActor
func runPaneOpenFloatingTests() {
    let url = scratchDirectory().appendingPathComponent("float.sqlite")
    let store = reopened(url, key: SymmetricKey(size: .bits256))
    let coordinator = AppCoordinator(store: store)
    let note = try! store.create(title: "Float me", body: "x")
    coordinator.openFloating(noteID: note.id)
    expectTrue("open: from All Notes the note floats", coordinator.noteWindowForTesting(note.id)?.presentation == .detached)
    expectTrue("open: and comes back floating at the next launch", AppSettings.shared.floatingNoteIDs.contains(note.id))
    coordinator.noteWindowForTesting(note.id)?.close()

    // Already open on the deck: it is lifted off, not opened twice.
    coordinator.open(noteID: note.id, from: nil)
    let anchored = coordinator.noteWindowForTesting(note.id)
    expectTrue("open: first anchored", anchored?.presentation == .anchored)
    coordinator.openFloating(noteID: note.id)
    expectTrue("open: the same window", coordinator.noteWindowForTesting(note.id) === anchored)
    expectTrue("open: now floating", anchored?.presentation == .detached)
    anchored?.close()
    AppSettings.shared.setFloating(false, noteID: note.id)
}

/// New Note in All Notes: made for the list on show, selected, the caret in
/// its title inside the pane.
@MainActor
func runPaneNewNoteTests() {
    let url = scratchDirectory().appendingPathComponent("new.sqlite")
    let store = reopened(url, key: SymmetricKey(size: .bits256))
    let coordinator = AppCoordinator(store: store)
    _ = try! store.create(title: "Tagged", body: "x", tags: ["work"])
    let savedSelection = AppSettings.shared.allNotesSelection
    defer { AppSettings.shared.allNotesSelection = savedSelection }

    func titleHasCaret(_ window: NSWindow?, _ name: String) {
        guard let window else { expectTrue("new: \(name): All Notes is open", false); return }
        var editing = false
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            spin(0.05)
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
               (editor.delegate as? NSTextField)?.placeholderString == L("Title") {
                editing = true
                break
            }
        }
        expectTrue("new: \(name): the caret is in the pane's title", editing)
    }

    // On a tag's list: the note has the tag.
    AppSettings.shared.allNotesSelection = NoteSelection.tag("work").storageValue
    let tagged = coordinator.newNoteInAllNotes()!
    expect("new: on a tag's list it has the tag", store.note(id: tagged)?.tags.joined(separator: ","), "work")
    titleHasCaret(coordinator.allNotesWindowForTesting, "tag")
    expect("new: the pane edits it", coordinator.paneNoteID?.uuidString, tagged.uuidString)

    // On Daily, with All Notes already open: today's daily.
    AppSettings.shared.allNotesSelection = NoteSelection.library(.daily).storageValue
    let daily = coordinator.newNoteInAllNotes()!
    let made = store.note(id: daily)
    expectTrue("new: on Daily it is a daily", made?.isDaily == true)
    expect("new: of today", made?.dailyDay?.string, store.today.string)
    expectTrue("new: titled as dailies are", made?.title.hasPrefix(L("Daily")) == true)
    titleHasCaret(coordinator.allNotesWindowForTesting, "daily")
    expect("new: the pane edits the daily", coordinator.paneNoteID?.uuidString, daily.uuidString)

    // On Archived: a new note is on the deck, so All Notes shows it.
    AppSettings.shared.allNotesSelection = NoteSelection.library(.archived).storageValue
    let plain = coordinator.newNoteInAllNotes()!
    expectTrue("new: from Archived it is on the deck", store.note(id: plain)?.state == .active)
    expect("new: and the list moves to All Notes", AppSettings.shared.allNotesSelection, NoteSelection.default.storageValue)
    titleHasCaret(coordinator.allNotesWindowForTesting, "archived")
    coordinator.allNotesWindowForTesting?.close()
}
