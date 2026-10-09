import AppKit
import SwiftUI

/// What the note model can ask of the tags field it is attached to.
@MainActor
protocol TagFieldHandle: AnyObject {
    /// Replaces the whole text and puts the caret at `caret`.
    func apply(text: String, caret: Int)
    /// Takes keyboard focus back into the field.
    func focus()
    /// Whether the field is the window's first responder right now.
    var isFocused: Bool { get }
    /// The caret (end of the selection), or the end of the text.
    var caretPosition: Int { get }
}

/// The tags field as a real `NSTextField`: SwiftUI's `TextField` cannot report
/// the caret or intercept the arrow keys, and the suggestion list needs both.
/// It reports every edit, caret move and focus change to the model, which owns
/// the suggestions.
struct TagField: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var model: NoteEditorModel
    var ink: NSColor
    var isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, model: model) }

    func makeNSView(context: Context) -> TagTextField {
        let field = TagTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11.5)
        field.placeholderString = "Add tags"
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }
        context.coordinator.field = field
        model.tagField = context.coordinator
        return field
    }

    func updateNSView(_ field: TagTextField, context: Context) {
        context.coordinator.text = $text
        field.isEnabled = isEnabled
        field.textColor = ink
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, TagFieldHandle {
        var text: Binding<String>
        unowned let model: NoteEditorModel
        weak var field: TagTextField?

        init(text: Binding<String>, model: NoteEditorModel) {
            self.text = text
            self.model = model
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        // MARK: Focus

        func focusChanged(_ focused: Bool) {
            if focused { observeSelection() }
            model.tagFieldFocusChanged(focused, caret: caret)
        }

        /// The field editor posts selection changes, so moving the caret with
        /// the arrow keys or the mouse retargets the suggestions too.
        private func observeSelection() {
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionChanged(_:)),
                name: NSTextView.didChangeSelectionNotification, object: nil
            )
        }

        @objc private func selectionChanged(_ note: Notification) {
            guard let field, let editor = note.object as? NSTextView, editor === field.currentEditor() else { return }
            model.tagFieldEdited(text: field.stringValue, caret: caret)
        }

        /// The end of the selection: with the whole field selected (as when
        /// tabbing in) that is the end of the text, where the next tag goes.
        private var caret: Int {
            guard let editor = field?.currentEditor() else { return (field?.stringValue as NSString?)?.length ?? 0 }
            return NSMaxRange(editor.selectedRange)
        }

        // MARK: Editing

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            text.wrappedValue = field.stringValue
            model.tagFieldEdited(text: field.stringValue, caret: caret)
        }

        /// Arrows move through the suggestions, Return and Tab take the
        /// highlighted one, Esc closes the list. With nothing to take, Return
        /// tidies the field into `#a #b` as it always has and Tab is left to
        /// AppKit.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                guard model.isTagListVisible || model.isTagFieldFocused else { return false }
                model.moveTagSelection(by: -1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                guard model.isTagListVisible || model.isTagFieldFocused else { return false }
                model.moveTagSelection(by: 1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if !model.acceptSelectedTag() { model.tidyTags() }
                return true
            case #selector(NSResponder.insertTab(_:)):
                return model.acceptSelectedTag()
            case #selector(NSResponder.cancelOperation(_:)):
                guard model.isTagListVisible else { return false }
                model.dismissTagList()
                return true
            default:
                return false
            }
        }

        // MARK: TagFieldHandle

        func apply(text newText: String, caret: Int) {
            guard let field else { return }
            field.stringValue = newText
            if let editor = field.currentEditor() {
                editor.string = newText
                editor.selectedRange = NSRange(location: min(caret, (newText as NSString).length), length: 0)
            }
            text.wrappedValue = newText
            model.tagFieldEdited(text: newText, caret: caret)
        }

        var isFocused: Bool {
            guard let field, let window = field.window, let editor = field.currentEditor() else { return false }
            return window.firstResponder === editor
        }

        var caretPosition: Int { caret }

        func focus() {
            guard let field, let window = field.window else { return }
            if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
        }
    }
}

/// Tells its owner when it gains focus; losing it is `controlTextDidEndEditing`.
final class TagTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocusChange?(true) } }
        return accepted
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
