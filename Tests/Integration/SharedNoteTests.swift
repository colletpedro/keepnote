import AppKit
import CryptoKit
import SwiftUI

// MARK: - One note in a window and in All Notes' pane at once

/// Types at the caret of `body` (the end unless placed), as the keyboard would.
@MainActor
private func typeAt(_ body: NSTextView, _ text: String, location: Int? = nil) {
    let end = (body.string as NSString).length
    body.window?.makeFirstResponder(body)
    body.setSelectedRange(NSRange(location: location ?? end, length: 0))
    body.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
}

@MainActor
func runSharedNoteTests() {
    let url = scratchDirectory().appendingPathComponent("shared.sqlite")
    let key = SymmetricKey(size: .bits256)
    let store = reopened(url, key: key)
    let note = try! store.create(title: "Plan", body: "one")
    let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                  delete: { _ in }, export: { _ in })

    for floating in [false, true] {
        let place = floating ? "floating" : "anchored"
        try! store.setBody("one", id: note.id)
        let window = NoteWindowController(note: store.note(id: note.id)!, store: store, originFrame: nil,
                                          cascadeIndex: 0, floating: floating)
        window.window.contentView?.layoutSubtreeIfNeeded()
        let (paneWindow, pane) = hostAllNotes(store, actions: actions, selecting: [note.id])
        guard let inWindow = window.window.contentView.flatMap(textView(in:)), let inPane = textView(in: pane) else {
            expectTrue("shared (\(place)): both editors are there", false)
            continue
        }
        func settle() {
            window.window.contentView?.layoutSubtreeIfNeeded()
            pane.layoutSubtreeIfNeeded()
            spin(0.05)
        }

        // Typed in the pane: in the window at once, before anything is written.
        typeAt(inPane, " two")
        settle()
        expect("shared (\(place)): the pane's typing is in the window at once", inWindow.string, "one two")
        expect("shared (\(place)): before the autosave has run", store.note(id: note.id)?.body, "one")

        // Typed in the window straight after, inside the same autosave pause:
        // both edits are there, in both places.
        typeAt(inWindow, " three")
        settle()
        expect("shared (\(place)): the window's typing is in the pane at once", inPane.string, "one two three")

        // In the middle of the text, from the pane, while the window's edit
        // still waits to be written.
        typeAt(inPane, "zero ", location: 0)
        settle()
        expect("shared (\(place)): an edit at the start shows in the window", inWindow.string, "zero one two three")

        // Nothing lost once written, and nothing lost across a relaunch.
        spin(0.5)
        expect("shared (\(place)): every edit is written", store.note(id: note.id)?.body, "zero one two three")
        store.waitUntilSaved()
        expect("shared (\(place)): and is what a later launch finds", reopened(url, key: key).note(id: note.id)?.body,
               "zero one two three")

        // The title, the same way.
        if let field = titleField(in: pane) {
            paneWindow.makeFirstResponder(field)
            (paneWindow.firstResponder as? NSTextView)?.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            settle()
            let windowTitle = window.window.contentView.flatMap(titleField(in:))?.stringValue
            expectTrue("shared (\(place)): the pane's title is in the window (\(windowTitle ?? "nil"))", windowTitle?.hasSuffix("!") == true)
            paneWindow.makeFirstResponder(nil)
        }

        // Closing the window leaves the pane editing, and its edits still save.
        window.close()
        typeAt(inPane, " four")
        spin(0.5)
        expect("shared (\(place)): with the window closed the pane still saves", store.note(id: note.id)?.body,
               "zero one two three four")

        // An edit typed in the window and closed before the pause is over is
        // written too: closing writes what is waiting.
        let again = NoteWindowController(note: store.note(id: note.id)!, store: store, originFrame: nil,
                                         cascadeIndex: 0, floating: floating)
        again.window.contentView?.layoutSubtreeIfNeeded()
        if let body = again.window.contentView.flatMap(textView(in:)) {
            expect("shared (\(place)): a window opened later starts from the pane's text", body.string, "zero one two three four")
            typeAt(body, " five")
        }
        again.close()
        expect("shared (\(place)): closing writes at once", store.note(id: note.id)?.body, "zero one two three four five")
        pane.layoutSubtreeIfNeeded()
        spin(0.05)
        expect("shared (\(place)): and the pane shows it", textView(in: pane)?.string, "zero one two three four five")
        paneWindow.close()
        spin(0.05)
        try! store.setTitle("Plan", id: note.id)
    }
}
