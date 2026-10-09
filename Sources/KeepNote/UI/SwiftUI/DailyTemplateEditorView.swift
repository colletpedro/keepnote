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
    @Published private(set) var isSaving = false
    /// When the text last changed; `nil` while the template was never written.
    @Published private(set) var editedAt: Date?

    private let store: NoteStore
    private let debouncer: Debouncer
    private var subscription: AnyCancellable?

    init(store: NoteStore) {
        self.store = store
        self.text = store.dailyTemplate.body
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

    private func commit() {
        store.setDailyTemplate(text)
        editedAt = store.dailyTemplate.isSet ? store.dailyTemplate.updatedAt : nil
        isSaving = false
    }

    private func refresh(from template: DailyTemplate) {
        // What was just typed is not undone by what arrives meanwhile.
        guard !debouncer.hasPendingWork else { return }
        if template.body != text { text = template.body }
        editedAt = template.isSet ? template.updatedAt : nil
    }

    func statusLabel(now: Date) -> String {
        if isSaving { return SaveStatus.label(isSaving: true, editedAt: now, now: now) }
        guard let editedAt else { return "" }
        return SaveStatus.label(isSaving: false, editedAt: editedAt, now: now)
    }
}

/// The window the daily template is edited in: the editor of a note — lists,
/// checklists, shortcuts, the Tools menu — on a note's paper, with the title
/// fixed. Below it, a line saying which variables the text may hold.
struct DailyTemplateEditorView: View {
    static let title = "Daily Template"
    static let placeholder = "Write what a new daily note should start with."
    static let help = "Use {date} for today\u{2019}s date and {weekday} for the day of the week. They are filled in when a new daily note is created."

    @ObservedObject var model: DailyTemplateModel
    var onShowTools: () -> Void = {}

    private let color = NoteColor.default

    var body: some View {
        HStack(spacing: 0) {
            spine
            VStack(spacing: 0) {
                header
                ZStack(alignment: .topLeading) {
                    NoteTextView(text: $model.text, color: color, findQuery: "", findIndex: 0)
                    if model.text.isEmpty {
                        Text(Self.placeholder)
                            .font(.system(size: MarkdownStyler.baseSize))
                            .foregroundStyle(color.secondaryInkSwiftUI)
                            .padding(.horizontal, 14 + 5)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
                footer
            }
        }
        .background(color.surfaceSwiftUI)
    }

    private var spine: some View {
        ZStack {
            color.spineSwiftUI
            SpineLabel(text: Self.title, color: color.inkSwiftUI.opacity(0.78))
            HStack {
                Spacer()
                PerforationLine(color: color.inkSwiftUI.opacity(0.28))
                    .padding(.vertical, 10)
            }
        }
        .frame(width: EdgeMetrics.tabWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(Self.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color.inkSwiftUI)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Re-evaluated every 30 s, so "5 min ago" keeps counting.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(model.statusLabel(now: context.date))
                    .font(.system(size: 12))
                    .foregroundStyle(color.secondaryInkSwiftUI)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button(action: onShowTools) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(color.secondaryInkSwiftUI)
            .help("Tools")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        Text(Self.help)
            .font(.system(size: 11.5))
            .foregroundStyle(color.secondaryInkSwiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                ZStack(alignment: .top) {
                    color.surfaceSwiftUI
                    Rectangle()
                        .fill(color.inkSwiftUI.opacity(0.12))
                        .frame(height: 1)
                }
            )
    }
}
