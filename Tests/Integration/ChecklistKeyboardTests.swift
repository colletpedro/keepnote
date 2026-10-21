import AppKit
import CryptoKit

/// A checklist without the mouse: ⌘Return ticks the task the caret is on,
/// and VoiceOver sees each box as a checkbox it can press.
@MainActor
func runChecklistKeyboardTests() {
    let url = scratchDirectory().appendingPathComponent("checklist-\(UUID().uuidString).sqlite")
    let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
    let note = try! store.create(title: "Tasks", body: "- [ ] Buy milk\n- [x] Call Ana\nplain")
    let controller = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0)
    controller.window.layoutIfNeeded()
    spin(0.2)
    guard let view = textView(in: controller.window.contentView!) as? MarkdownTextView else {
        expectTrue("checklist: the text view", false)
        return
    }
    let boxes = view.checklistBoxes()
    expect("VoiceOver: a checkbox per task", boxes.map { $0.accessibilityLabel() ?? "" }.joined(separator: ","), "Buy milk,Call Ana")
    expect("VoiceOver: ticked or not", boxes.map { "\($0.accessibilityValue() ?? "")" }.joined(separator: ","), "0,1")
    expectTrue("VoiceOver: checkboxes", boxes.allSatisfy { $0.accessibilityRole() == .checkBox })
    _ = boxes.first?.accessibilityPerformPress()
    expect("VoiceOver: pressing ticks it", view.string.components(separatedBy: "\n").first, "- [x] Buy milk")

    controller.window.makeFirstResponder(view)
    view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "Call").location, length: 0))
    let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                         windowNumber: controller.window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    expectTrue("keyboard: ⌘Return is taken on a task", view.performKeyEquivalent(with: commandReturn))
    expect("keyboard: and unticks it", view.string.components(separatedBy: "\n")[1], "- [ ] Call Ana")
    view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "plain").location, length: 0))
    expectTrue("keyboard: on a line with no task it is left alone", !view.performKeyEquivalent(with: commandReturn))
    controller.close()
}
