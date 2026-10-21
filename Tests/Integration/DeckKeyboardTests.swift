import AppKit
import CryptoKit

/// Focus Deck: the deck with the keyboard. Arrows move between the tabs and
/// the buttons, Space peeks, Return opens, Esc gives the keyboard back.
@MainActor
func runDeckKeyboardTests() {
    final class Delegate: EdgePanelControllerDelegate {
        var opened: UUID?
        var newNotes = 0
        func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?) { opened = id }
        func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID) {}
        func edgePanelDidRequestNewNote(_ controller: EdgePanelController) { newNotes += 1 }
        func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController) {}
        func edgePanelDidRequestAllNotes(_ controller: EdgePanelController) {}
        func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu? { nil }
    }
    let url = scratchDirectory().appendingPathComponent("deck-keys-\(UUID().uuidString).sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
    _ = try! store.create((0..<4).map { NoteDraft(title: "Tab \($0)") })
    let controller = EdgePanelController(screen: NSScreen.main ?? NSScreen.screens[0])
    let delegate = Delegate()
    controller.delegate = delegate
    controller.update(notes: store.notes)
    let stack = controller.stackViewForTesting
    func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) {
        stack.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                             context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false,
                                             keyCode: UInt16(code))!)
    }
    func focused() -> String { stack.keyboardStop?.accessibilityLabel() ?? "none" }
    let order = { stack.accessibilityOrderForTesting.map { $0.accessibilityLabel() ?? "" } }

    expect("focus deck: the shortcut", GlobalCommand.focusDeck.defaultCombo.displayString, "\u{2303}\u{2325}\u{2318}D")
    controller.focusFromKeyboard()
    spin(0.2)
    expectTrue("focus deck: the deck opens and takes the keyboard", controller.isFanned && controller.isKeyboardFocused)
    expect("focus deck: on the first tab", focused(), order().first)
    expectTrue("focus deck: the tab is drawn focused", (stack.keyboardStop as? NoteCardView)?.showsKeyboardFocus == true)
    expectTrue("focus deck: and opened as a hover opens it", stack.hoveredNoteID == (stack.keyboardStop as? NoteCardView)?.noteID)
    expectTrue("focus deck: no peek until Space", controller.peekForTesting.noteID == nil)
    key(125)
    expect("arrows: down to the next tab", focused(), order()[1])
    key(126)
    expect("arrows: up again", focused(), order()[0])
    key(126)
    expect("arrows: stops at the top", focused(), order()[0])
    key(48)
    expect("Tab: moves on too", focused(), order()[1])
    key(48, .shift)
    expect("Shift-Tab: back", focused(), order()[0])
    key(49)
    expectTrue("Space: the peek", controller.peekForTesting.noteID == (stack.keyboardStop as? NoteCardView)?.noteID)
    key(49)
    expectTrue("Space again: the peek goes", controller.peekForTesting.noteID == nil)
    key(119)
    expect("End: the last stop", focused(), "Today\u{2019}s Daily")
    key(126)
    expect("then up to the +", focused(), "New Note")
    key(36)
    expect("Return on +: a new note", String(delegate.newNotes), "1")
    expectTrue("and the keyboard goes back", !controller.isKeyboardFocused)

    controller.focusFromKeyboard()
    key(125)
    let second = (stack.keyboardStop as? NoteCardView)?.noteID
    key(36)
    expectTrue("Return on a tab: the note opens", delegate.opened != nil && delegate.opened == second)

    controller.focusFromKeyboard()
    key(53)
    expectTrue("Esc: the keyboard goes back", !controller.isKeyboardFocused && stack.keyboardStop == nil)
    expectTrue("Esc: and the deck folds away", !controller.isFanned)
    controller.hidePanel()
}
