import AppKit
import Combine
import SwiftUI

/// Editing state for the daily template, the way `NoteEditorModel` keeps a
/// note's: the view writes here on every keystroke, and the store is written
/// once the user has been quiet for the autosave delay.
@MainActor
final class DailyTemplateModel: ObservableObject {
    @Published var text: String {
        didSet { guard text != oldValue else { return }; scheduleSave() }
    }
    /// The card's colour, and the colour of every daily born from it.
    @Published private(set) var color: NoteColor
    @Published private(set) var isSaving = false
    /// When the text or colour last changed; `nil` while the template was never written.
    @Published private(set) var editedAt: Date?

    private let store: NoteStore
    private let debouncer: Debouncer
    private var subscription: AnyCancellable?

    init(store: NoteStore) {
        self.store = store
        self.text = store.dailyTemplate.body
        self.color = store.dailyTemplate.color
        self.editedAt = store.dailyTemplate.isSet ? store.dailyTemplate.updatedAt : nil
        self.debouncer = Debouncer(delay: AppSettings.shared.autosaveDelay)
        // A template that arrives from the sync folder or an import, while the
        // window is open. `$dailyTemplate` announces before it changes, so the
        // new value is the argument, not the property.
        subscription = store.$dailyTemplate
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] template in self?.refresh(from: template) }
    }

    func flush() { debouncer.flush() }

    private func scheduleSave() {
        isSaving = true
        debouncer.schedule { [weak self] in self?.commit() }
    }

    /// A swatch was chosen: the colour is written at once, with whatever text
    /// was waiting, and the card takes it. Dailies that already exist keep theirs.
    func setColor(_ new: NoteColor) {
        flush()
        store.setDailyTemplate(color: new)
        color = store.dailyTemplate.color
        editedAt = store.dailyTemplate.isSet ? store.dailyTemplate.updatedAt : nil
    }

    private func commit() {
        store.setDailyTemplate(text)
        editedAt = store.dailyTemplate.isSet ? store.dailyTemplate.updatedAt : nil
        isSaving = false
    }

    private func refresh(from template: DailyTemplate) {
        // What was just typed is not undone by what arrives meanwhile.
        guard !debouncer.hasPendingWork else { return }
        if template.body != text { text = template.body }
        color = template.color
        editedAt = template.isSet ? template.updatedAt : nil
    }

    func statusLabel(now: Date) -> String {
        if isSaving { return SaveStatus.label(isSaving: true, editedAt: now, now: now) }
        guard let editedAt else { return "" }
        return SaveStatus.label(isSaving: false, editedAt: editedAt, now: now)
    }
}

/// The words around the template.
enum DailyTemplateText {
    static let title = "Daily Template"
    static let placeholder = "Write what a new daily note should start with."
    static let help = "Use {date} for today\u{2019}s date and {weekday} for the day of the week. They are filled in when a new daily note is created. New daily notes use this color."
}

// MARK: - In All Notes

/// The template as it appears in All Notes: a card like a note's, editable in
/// place with the full editor, and under it the line that explains the
/// variables. Saves on its own, as notes do.
struct DailyTemplatePane: View {
    /// The fixed row at the top of the Daily list stands for the template in
    /// the list's selection. It is not a note and has no row in the store.
    static let rowID = UUID(uuidString: "00000000-0000-0000-0000-00000000DA17")!

    @StateObject private var model: DailyTemplateModel

    init(store: NoteStore) {
        _model = StateObject(wrappedValue: DailyTemplateModel(store: store))
    }

    /// The container of an ordinary note in this pane: a stack with the same
    /// 16 pt margin, an info bar above the card, the card below it. The card
    /// takes what is left and the text scrolls inside it.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoBar
            DailyTemplateCard(model: model, onShowTools: DailyTemplateCard.showTools)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
            // No `fixedSize` here: pinning the line to its ideal height made
            // the stack size itself from the card's ideal size instead of
            // the pane's, and the card grew past it (see the render tests).
            Text(DailyTemplateText.help)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .onDisappear { model.flush() }
    }

    private var infoBar: some View {
        HStack(spacing: 8) {
            Text("Starts every new daily note")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(model.statusLabel(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 22)
    }
}

/// The paper of the template: spine, title, editor.
struct DailyTemplateCard: View {
    @ObservedObject var model: DailyTemplateModel
    var onShowTools: () -> Void = {}

    private var color: NoteColor { model.color }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                color.spineSwiftUI
                SpineLabel(text: DailyTemplateText.title, color: color.inkSwiftUI.opacity(0.78), topInset: 4)
                HStack {
                    Spacer()
                    PerforationLine(color: color.inkSwiftUI.opacity(0.28))
                        .padding(.vertical, 10)
                }
            }
            .frame(width: EdgeMetrics.tabWidth)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(DailyTemplateText.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color.inkSwiftUI)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: onShowTools) {
                        Image(systemName: "wrench.and.screwdriver").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(color.secondaryInkSwiftUI)
                    .help("Tools")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)

                ZStack(alignment: .topLeading) {
                    NoteTextView(text: $model.text, color: color, findQuery: "", findIndex: 0)
                    if model.text.isEmpty {
                        Text(DailyTemplateText.placeholder)
                            .font(.system(size: MarkdownStyler.baseSize))
                            .foregroundStyle(color.secondaryInkSwiftUI)
                            .padding(.horizontal, 14 + 5)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    NoteColorRow(selected: color) { model.setColor($0) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    ZStack(alignment: .top) {
                        color.surfaceSwiftUI
                        Rectangle().fill(color.inkSwiftUI.opacity(0.12)).frame(height: 1)
                    }
                )
            }
        }
        .background(color.surfaceSwiftUI)
        // The paper is always light, as in a note's window: text, caret and
        // placeholder stay dark on it in Dark Mode too.
        .environment(\.colorScheme, .light)
    }

    /// The Tools button: the note editor's menu, acting on the text directly.
    static func showTools() {
        guard let window = NSApp.keyWindow, let content = window.contentView,
              let textView = findTextView(in: content) else { return }
        let menu = FormatCommand.makeToolsMenu(target: textView)
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: point, in: content)
        let kept = textView.selectedRange()
        window.makeFirstResponder(textView)
        textView.setSelectedRange(kept)
    }

    static func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.identifier == NoteTextView.bodyIdentifier, !textView.isFieldEditor {
            return textView
        }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
    }
}
