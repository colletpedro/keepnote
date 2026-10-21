import AppKit
import SwiftUI

/// The AppKit half of the editor in All Notes' pane: what a note window does
/// for its own editor — the Tools menu aimed at the body, the note's
/// shortcuts, where the caret goes — done for the editor inside All Notes.
///
/// It knows the editor by `anchor`, a view laid out under it that takes no
/// clicks. A responder belongs to the pane when it sits inside the anchor's
/// rectangle in the same window, which tells the pane's body and title apart
/// from the list's, the sidebar's and the search field's.
@MainActor
final class PaneEditorController: ObservableObject {
    weak var model: NoteEditorModel?
    var onSetPinned: (Bool) -> Void = { _ in }
    var onSetKeepOnDeck: (Bool) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onOpen: () -> Void = {}

    fileprivate(set) weak var anchor: NSView?
    private var keyMonitor: Any?

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    fileprivate func attach(_ view: NSView) {
        anchor = view
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    fileprivate func detach() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: - Finding the editor's views

    private var window: NSWindow? { anchor?.window }

    private var anchorRect: NSRect? {
        guard let anchor, anchor.window != nil else { return nil }
        return anchor.convert(anchor.bounds, to: nil)
    }

    /// The view `responder` stands for: a field editor stands for its field.
    private static func view(for responder: NSResponder?) -> NSView? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field
        }
        return responder as? NSView
    }

    /// Whether `view` is part of the pane's editor.
    func contains(_ view: NSView?) -> Bool {
        guard let view, let rect = anchorRect, view.window === window else { return false }
        let visible = view.convert(view.visibleRect, to: nil)
        return rect.contains(NSPoint(x: visible.midX, y: visible.midY))
    }

    /// The keyboard is in the pane's editor: its body, title, tags or find field.
    var hasFocus: Bool { contains(Self.view(for: window?.firstResponder)) }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func editorViews() -> [NSView] {
        guard let content = window?.contentView else { return [] }
        return descendants(of: content).filter { contains($0) }
    }

    var bodyView: NSTextView? {
        editorViews().lazy.compactMap { $0 as? NSTextView }
            .first { $0.identifier == NoteTextView.bodyIdentifier && !$0.isFieldEditor }
    }

    var titleField: NSTextField? {
        editorViews().lazy.compactMap { $0 as? NSTextField }.first { $0.placeholderString == L("Title") }
    }

    private var isTitleEditing: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return false }
        return field.placeholderString == L("Title") && contains(field)
    }

    // MARK: - The caret

    /// The caret at the end of the body, nothing selected.
    @discardableResult
    func focusBody() -> Bool {
        guard let window, let body = bodyView else { return false }
        window.makeFirstResponder(body)
        let end = (body.string as NSString).length
        body.setSelectedRange(NSRange(location: end, length: 0))
        body.scrollRangeToVisible(NSRange(location: end, length: 0))
        return true
    }

    /// The caret in the title, for a note just made.
    @discardableResult
    func focusTitle() -> Bool {
        guard let window, let field = titleField else { return false }
        return window.makeFirstResponder(field)
    }

    // MARK: - Tools

    /// The same menu as a note window's: formatting aimed at the body, then
    /// Pin to Center and Keep on Deck.
    func showTools() {
        guard let anchor, let window, let body = bodyView else { return }
        let menu = FormatCommand.makeToolsMenu(target: body)
        menu.addItem(.separator())
        let pin = NSMenuItem(title: L("Pin to Center"), action: #selector(MenuTarget.pin), keyEquivalent: "")
        pin.state = model?.isPinned == true ? .on : .off
        pin.isEnabled = model?.state != .archived
        let keep = NSMenuItem(title: L("Keep on Deck"), action: #selector(MenuTarget.keep), keyEquivalent: "")
        keep.state = model?.keepOnDeck == true ? .on : .off
        let target = MenuTarget(
            pin: { [weak self] in self?.onSetPinned(!(self?.model?.isPinned ?? false)) },
            keep: { [weak self] in self?.onSetKeepOnDeck(!(self?.model?.keepOnDeck ?? false)) }
        )
        pin.target = target
        keep.target = target
        menu.autoenablesItems = false
        menu.addItem(pin)
        menu.addItem(keep)
        let point = anchor.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let kept = body.selectedRange()
        menu.popUp(positioning: nil, at: point, in: anchor)
        withExtendedLifetime(target) {}
        window.makeFirstResponder(body)
        body.setSelectedRange(kept)
    }

    private final class MenuTarget: NSObject {
        let onPin: () -> Void
        let onKeep: () -> Void
        init(pin: @escaping () -> Void, keep: @escaping () -> Void) {
            onPin = pin
            onKeep = keep
        }
        @objc func pin() { onPin() }
        @objc func keep() { onKeep() }
    }

    // MARK: - Keys

    /// The note's shortcuts while the keyboard is in the pane's editor, as in
    /// a note window. Returns whether the key was taken.
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let model, hasFocus else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Esc closes the tag suggestions, as in a note.
        if event.keyCode == 53, flags.isEmpty, model.isTagListVisible {
            model.dismissTagList()
            return true
        }

        // Return or Tab in the title moves on to the body.
        if flags.isEmpty, [36, 76, 48].contains(event.keyCode), isTitleEditing,
           let editor = window.firstResponder as? NSTextView, !editor.hasMarkedText() {
            focusBody()
            return true
        }

        if let command = ShortcutStore.shared.noteCommand(for: event) {
            switch command {
            case .find: model.toggleFindBar()
            case .findNext: model.advanceFind(by: 1)
            case .findPrevious: model.advanceFind(by: -1)
            case .nextColor: model.cycleColor(backwards: false)
            case .previousColor: model.cycleColor(backwards: true)
            case .archive: model.toggleComplete()
            case .float: onOpen()
            case .delete:
                model.flush()
                onDelete()
            }
            return true
        }
        return false
    }
}

/// Lays out under the pane's editor and tells its controller where that is.
/// Never takes a click: everything is the editor's.
struct PaneEditorAnchor: NSViewRepresentable {
    let controller: PaneEditorController

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.controller = controller
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.controller?.detach()
    }

    final class AnchorView: NSView {
        weak var controller: PaneEditorController?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { controller?.attach(self) } else { controller?.detach() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
