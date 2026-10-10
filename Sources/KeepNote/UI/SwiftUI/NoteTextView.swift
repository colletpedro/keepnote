import AppKit
import SwiftUI

/// The note body, backed by a real `NSTextView`.
///
/// SwiftUI's `TextEditor` cannot highlight arbitrary ranges, and find-in-note
/// is part of the spec, so the editor drops down to AppKit and paints matches
/// with temporary attributes — which do not touch the stored text.
struct NoteTextView: NSViewRepresentable {
    static let bodyIdentifier = NSUserInterfaceItemIdentifier("KeepNote.noteBody")

    @Binding var text: String
    var color: NoteColor
    var findQuery: String
    var findIndex: Int
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than with `NSTextView.scrollableTextView()`: the
        // body needs `MarkdownTextView`, and an explicit TextKit 1 stack keeps
        // the layout manager (find highlights, decorations) predictable.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        // The paper is light in every mode, so the text on it resolves in Aqua.
        scrollView.appearance = NSAppearance(named: .aqua)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        // Room below the last line, so the text never ends flush against the
        // footer when the note is scrolled to the bottom.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 18, right: 0)

        // Tagged so the window controller can find *this* text view rather than
        // whichever NSTextView happens to come first in the hierarchy — a
        // focused title field installs the window's field editor, which is also
        // an NSTextView and sits earlier in the tree.
        textView.identifier = NoteTextView.bodyIdentifier
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = NSFont.systemFont(ofSize: MarkdownStyler.baseSize)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.string = text

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.styler = MarkdownStyler(ink: color.ink, accent: color.accent, highlight: color.spine)
        textView.onWidthChange = { [weak coordinator] in coordinator?.restyle(force: true) }
        coordinator.restyle(force: true)
        return scrollView
    }

    /// The editor takes the room it is offered and never asks for more: a
    /// scroll view's own size follows its text, so left to itself a long text
    /// would stretch whatever holds it — the window included.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 120)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        var needsRestyle = false

        // Only write back when the model genuinely diverged, otherwise every
        // keystroke would reset the insertion point.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
            needsRestyle = true
        }

        let styler = MarkdownStyler(ink: color.ink, accent: color.accent, highlight: color.spine)
        if coordinator.styler != styler {
            coordinator.styler = styler
            needsRestyle = true
        }

        textView.insertionPointColor = color.accent
        textView.isEditable = isEditable
        if needsRestyle { coordinator.restyle(force: true) }
        coordinator.applyHighlight(query: findQuery, index: findIndex, accent: color.spine)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var styler = MarkdownStyler(ink: .labelColor, accent: .controlAccentColor, highlight: .controlAccentColor)
        /// Where the caret was at the last restyle, so a selection change that
        /// did not move anything does not restyle the whole note.
        private var lastSelection: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            restyle(force: true)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            restyle(force: false)
        }

        /// Re-applies markdown styling. Syntax stays hidden except around the
        /// caret or selection, exactly as in Obsidian's Live Preview.
        func restyle(force: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            // Composing an accent (dead key, IME) must not be restyled mid-way.
            guard !textView.hasMarkedText() else { return }

            let selection = textView.selectedRange()
            if !force, selection == lastSelection { return }
            lastSelection = selection

            let container = textView.textContainer
            let tableWidth = (container?.size.width ?? 0) - 2 * (container?.lineFragmentPadding ?? 0)

            styler.apply(to: storage, selection: selection, tableWidth: tableWidth)
            textView.typingAttributes = styler.baseAttributes
            if let markdownView = textView as? MarkdownTextView {
                markdownView.accentColor = styler.accent
                markdownView.inkColor = styler.ink
            }
            textView.needsDisplay = true
        }

        /// Highlights every match, and marks the current one more strongly.
        /// Temporary attributes live in the layout manager only, so nothing
        /// here can end up in the encrypted body.
        func applyHighlight(query: String, index: Int, accent: NSColor) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)

            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let ranges = NoteTextView.matchRanges(in: textView.string, query: trimmed)
            guard !ranges.isEmpty else { return }

            for (offset, range) in ranges.enumerated() {
                let isCurrent = offset == ((index % ranges.count) + ranges.count) % ranges.count
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: accent.withAlphaComponent(isCurrent ? 0.55 : 0.22),
                    forCharacterRange: range
                )
            }

            let current = ranges[((index % ranges.count) + ranges.count) % ranges.count]
            textView.scrollRangeToVisible(current)
        }
    }

    /// Case-insensitive, diacritic-insensitive, shared by the view and by the
    /// "n of m" counter in the find bar.
    static func matchRanges(in haystack: String, query: String) -> [NSRange] {
        let text = haystack as NSString
        guard !query.isEmpty, text.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.location < text.length {
            let found = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            let next = found.location + max(found.length, 1)
            searchRange = NSRange(location: next, length: max(0, text.length - next))
        }
        return ranges
    }
}
