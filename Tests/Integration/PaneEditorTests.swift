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
