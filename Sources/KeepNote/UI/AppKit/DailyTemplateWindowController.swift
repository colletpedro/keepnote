import AppKit
import SwiftUI

/// The window the daily template is edited in. An ordinary titled window — it
/// is opened from All Notes, Settings and the menus, not from the deck — with
/// a note's paper inside, which is always light, like a note's.
@MainActor
final class DailyTemplateWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private let model: DailyTemplateModel
    private let hosting: NSHostingView<DailyTemplateEditorView>

    init(store: NoteStore) {
        model = DailyTemplateModel(store: store)
        hosting = NSHostingView(rootView: DailyTemplateEditorView(model: model))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 520, height: 460)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        hosting.rootView = DailyTemplateEditorView(model: model, onShowTools: { [weak self] in self?.showTools() })
        window.title = DailyTemplateEditorView.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        _ = window.setFrameAutosaveName("KeepNote.DailyTemplate")
        window.delegate = self
        if window.frame.origin == .zero { window.center() }
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        focusBody()
    }

    func close() { window.close() }

    func flush() { model.flush() }

    /// The Tools button: the note editor's menu, acting on the text directly,
    /// so choosing one works whether or not the text had focus.
    private func showTools() {
        guard let textView = Self.findTextView(in: hosting) else { return }
        let menu = FormatCommand.makeToolsMenu(target: textView)
        let point = hosting.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: hosting)
        let kept = textView.selectedRange()
        window.makeFirstResponder(textView)
        textView.setSelectedRange(kept)
    }

    /// The caret goes to the end of the text, ready to type. Deferred a turn:
    /// SwiftUI has not built the hosted hierarchy yet when the window is shown.
    private func focusBody() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let textView = Self.findTextView(in: self.hosting) else { return }
            self.window.makeFirstResponder(textView)
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView,
           textView.identifier == NoteTextView.bodyIdentifier,
           !textView.isFieldEditor {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.flush()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never leave typed text sitting in a timer when focus moves away.
        model.flush()
    }
}
