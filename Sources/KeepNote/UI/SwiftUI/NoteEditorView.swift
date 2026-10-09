import AppKit
import SwiftUI

/// How the open note is being shown.
///
/// `anchored` is the note still attached to the deck — tab on the left, sitting
/// where its card sat. `detached` is the note lifted off the edge: the tab
/// folds away and the full set of controls appears.
enum NotePresentation: Equatable {
    case anchored
    case detached
}

/// A drag on the spine or the header, reported to the window, which reads the
/// cursor itself: the window moves under the gesture, so the gesture's own
/// coordinates would chase it.
enum NoteDragPhase {
    case changed
    case ended
}

/// Editing state for one open note.
///
/// The view writes here on every keystroke; this object writes to the store
/// only once the user has been quiet for `autosaveDelay` (250 ms by default).
/// Everything else — colour, tags, complete, delete — is written straight
/// through, because those are deliberate single actions, not a stream.
@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var title: String {
        didSet { guard title != oldValue else { return }; scheduleSave() }
    }
    @Published var text: String {
        didSet { guard text != oldValue else { return }; scheduleSave() }
    }
    @Published var tagsText: String {
        didSet { guard tagsText != oldValue else { return }; scheduleSave() }
    }
    @Published private(set) var color: NoteColor
    @Published private(set) var editedAt: Date
    @Published private(set) var state: NoteState
    /// "Keep on Deck": the footer says so, and the Tools menu shows it ticked.
    @Published private(set) var keepOnDeck: Bool
    /// "Pin to Center": the header's pin is filled while it is on.
    @Published private(set) var isPinned: Bool
    /// Body could not be decrypted: the note is read-only and is never saved.
    @Published private(set) var isLocked: Bool

    @Published var isFindBarVisible = false
    @Published var findQuery = ""
    @Published var findIndex = 0

    // The tags field's suggestion list. `tagField` is the NSTextField the model
    // can hand edits back to.
    @Published private(set) var tagRows: [TagRow] = []
    @Published private(set) var tagSelection: Int?
    @Published private(set) var isTagFieldFocused = false
    weak var tagField: TagFieldHandle?
    private var tagCaret = 0
    private var lastTagText = ""
    private var tagBlurTask: Task<Void, Never>?
    /// Esc closed the list; typing (or focusing again) brings it back.
    private var tagListDismissed = false

    /// True from an edit until it is written; the header says "Saving…" only
    /// for that stretch.
    @Published private(set) var isSaving = false

    let noteID: UUID
    /// All Notes' reading pane edits only the tags; it never writes the title
    /// or body it loaded, so an open editor's newer text cannot be overwritten.
    var savesTagsOnly = false
    private let store: NoteStore
    private let debouncer: Debouncer

    init(note: Note, store: NoteStore) {
        self.noteID = note.id
        self.store = store
        self.title = note.title
        self.text = note.body
        self.tagsText = TagText.format(note.tags)
        self.color = note.color
        self.editedAt = note.editedAt
        self.state = note.state
        self.keepOnDeck = note.keepOnDeck
        self.isPinned = note.isPinned
        self.deckLine = DeckStatus.line(for: note)
        self.isLocked = note.isLocked
        self.debouncer = Debouncer(delay: AppSettings.shared.autosaveDelay)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var matchCount: Int {
        NoteTextView.matchRanges(in: text, query: findQuery.trimmingCharacters(in: .whitespacesAndNewlines)).count
    }

    var currentMatchNumber: Int {
        let count = matchCount
        guard count > 0 else { return 0 }
        return ((findIndex % count) + count) % count + 1
    }

    /// "Saving…" while a write is pending, otherwise "Edited 5 min ago".
    func statusLabel(now: Date) -> String {
        SaveStatus.label(isSaving: isSaving, editedAt: editedAt, now: now)
    }

    // MARK: - Saving

    private func scheduleSave() {
        guard !isLocked else { return }
        isSaving = true
        debouncer.schedule { [weak self] in self?.commit() }
    }

    /// Called by the debouncer, and directly whenever the note is about to
    /// close, the app deactivates, or the app is quitting.
    func flush() { debouncer.flush() }

    private func commit() {
        guard !isLocked else { return }
        let tags = TagText.parse(tagsText)
        do {
            try store.update(id: noteID) { note in
                if !self.savesTagsOnly {
                    note.title = self.title
                    note.body = self.text
                }
                note.tags = tags
            }
            if let refreshed = store.note(id: noteID) { editedAt = refreshed.editedAt }
            isSaving = false
        } catch {
            isSaving = false
            NSApp.presentError(error)
        }
    }

    // MARK: - Commands

    func cycleColor(backwards: Bool = false) {
        try? store.cycleColor(id: noteID, backwards: backwards)
        if let refreshed = store.note(id: noteID) { color = refreshed.color }
    }

    func setColor(_ newColor: NoteColor) {
        try? store.setColor(newColor, id: noteID)
        color = newColor
    }

    /// The spec's archive, under the name the design gives it: the note leaves
    /// the deck and keeps everything else.
    func toggleComplete() {
        try? store.toggleArchive(id: noteID)
        if let refreshed = store.note(id: noteID) { state = refreshed.state }
    }

    /// What the footer says about the note's place on the deck: kept, pinned,
    /// or about to be archived.
    @Published private(set) var deckLine: String?

    private func updateDeckLine(_ note: Note) {
        deckLine = DeckStatus.line(for: note)
    }

    func setKeepOnDeck(_ on: Bool) {
        try? store.setKeepOnDeck(on, id: noteID)
        if let refreshed = store.note(id: noteID) {
            keepOnDeck = refreshed.keepOnDeck
            updateDeckLine(refreshed)
        }
    }

    // MARK: - Tag suggestions

    var isTagListVisible: Bool { isTagFieldFocused && !tagListDismissed && !tagRows.isEmpty }

    /// Focus entering the field opens the list. Focus leaving closes it — after
    /// a beat, so that a click on a suggestion (which can end editing a moment
    /// before it lands) still gets through; accepting one takes focus back.
    func tagFieldFocusChanged(_ focused: Bool, caret: Int) {
        tagBlurTask?.cancel()
        if focused {
            isTagFieldFocused = true
            tagListDismissed = false
            tagCaret = caret
            refreshTagRows(text: tagsText, caret: caret)
        } else {
            tagBlurTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                self?.isTagFieldFocused = false
            }
        }
    }

    /// The note's window stopped being key (another app, a menu): nothing is
    /// being typed, so the list goes. It returns when the window does.
    func windowResignedKey() {
        tagBlurTask?.cancel()
        isTagFieldFocused = false
    }

    func windowBecameKey() {
        guard let field = tagField, field.isFocused else { return }
        tagFieldFocusChanged(true, caret: field.caretPosition)
    }

    /// The field's text or caret changed: suggestions follow the word under
    /// the caret, not just the last one.
    func tagFieldEdited(text: String, caret: Int) {
        tagCaret = caret
        if text != lastTagText { tagListDismissed = false }
        lastTagText = text
        refreshTagRows(text: text, caret: caret)
    }

    /// How many rows the note has room for; the view reports it.
    private var tagRowLimit = 7

    func setTagRowLimit(_ limit: Int) {
        guard limit != tagRowLimit else { return }
        tagRowLimit = limit
        if isTagFieldFocused { refreshTagRows(text: lastTagText, caret: tagCaret) }
    }

    private func refreshTagRows(text: String, caret: Int) {
        let token = TagText.token(in: text, caret: caret)
        let usage = DailyNotes.including(TagText.usage(of: store.notes.map(\.tags)))
        let counts = Dictionary(usage.map { ($0.tag, $0.count) }, uniquingKeysWith: +)
        let existing = TagText.parse(TagText.text(text, without: token))

        // "Create" is always the last row, so it is counted out of the room
        // the suggestions get.
        let creatable = TagText.createCandidate(for: token.name, usage: usage, existing: existing)
        let room = min(6, max(1, tagRowLimit - (creatable == nil ? 0 : 1)))
        let suggestions = TagText.suggestions(for: token.name, usage: usage, existing: existing, limit: room)

        tagRows = suggestions.map { .existing(tag: $0, count: counts[$0] ?? 0) }
            + (creatable.map { [.create(tag: $0)] } ?? [])
        tagSelection = TagText.initialSelection(token: token, suggestionCount: suggestions.count)
    }

    func hoverTagRow(_ index: Int) {
        if tagRows.indices.contains(index) { tagSelection = index }
    }

    /// Up and down move the highlight, wrapping around the ends. Down on a
    /// list that Esc closed opens it again.
    func moveTagSelection(by delta: Int) {
        if tagListDismissed {
            tagListDismissed = false
            return
        }
        tagSelection = TagText.moveSelection(tagSelection, count: tagRows.count, delta: delta)
    }

    /// Return or Tab: takes the highlighted suggestion. `false` when there is
    /// none, so the key does what it always did.
    @discardableResult
    func acceptSelectedTag() -> Bool {
        guard isTagListVisible, let index = tagSelection else { return false }
        acceptTagRow(at: index)
        return true
    }

    /// Esc closes the list and nothing else — the note stays open.
    func dismissTagList() { tagListDismissed = true }

    /// Puts the suggestion in place of the word under the caret and leaves the
    /// field ready for the next tag.
    func acceptTagRow(at index: Int) {
        guard tagRows.indices.contains(index) else { return }
        let result = TagText.accept(tagRows[index].tag, in: tagsText, caret: tagCaret)
        tagField?.apply(text: result.text, caret: result.caret)
        tagField?.focus()
    }

    /// Rewrites the tags field the way tags are stored: `#a #b`, lower-cased,
    /// without repeats.
    func tidyTags() {
        let tidy = TagText.format(TagText.parse(tagsText))
        if tidy != tagsText { tagsText = tidy }
    }

    func toggleFindBar() {
        isFindBarVisible.toggle()
        if !isFindBarVisible {
            findQuery = ""
            findIndex = 0
        }
    }

    func advanceFind(by delta: Int) {
        guard matchCount > 0 else { return }
        findIndex += delta
    }

    /// Refreshes from the store after a change that came from somewhere else —
    /// a sync pull, or an edit made in All Notes while the window was open.
    func refreshFromStore() {
        guard let note = store.note(id: noteID) else { return }
        color = note.color
        state = note.state
        keepOnDeck = note.keepOnDeck
        isPinned = note.isPinned
        updateDeckLine(note)
        editedAt = note.editedAt
        isLocked = note.isLocked
        if !debouncer.hasPendingWork {
            if note.title != title { title = note.title }
            if note.body != text { text = note.body }
            // Tags that arrived from sync or All Notes. The field is only
            // rewritten when it stands for different tags, so a spelling the
            // user typed is not reformatted under them.
            if TagText.fieldDiffers(from: note.tags, field: tagsText) { tagsText = TagText.format(note.tags) }
        }
    }
}

/// The open note. Same card as the tab in the deck, at full size.
struct NoteEditorView: View {
    @ObservedObject var model: NoteEditorModel
    var presentation: NotePresentation
    var onClose: () -> Void
    var onDelete: () -> Void
    var onTogglePin: () -> Void
    /// The header's pin: Pin to Center on or off.
    var onToggleCenterPin: () -> Void = {}
    var onShowTools: () -> Void = {}
    /// The `daily` chip was clicked: the window shows its menu of earlier dailies.
    var onDailyChip: () -> Void = {}
    var onDrag: (NoteDragPhase) -> Void = { _ in }

    /// Dragging the spine or the header moves the note: off the deck, around
    /// the desk, back onto the deck.
    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in onDrag(.changed) }
            .onEnded { _ in onDrag(.ended) }
    }

    @FocusState private var findFieldFocused: Bool
    @State private var footerHeight: CGFloat = 70

    var body: some View {
        HStack(spacing: 0) {
            spine
            content
        }
        .background(model.color.surfaceSwiftUI)
        .animation(.easeOut(duration: 0.15), value: model.isFindBarVisible)
        .onChange(of: model.isFindBarVisible) { visible in
            findFieldFocused = visible
        }
    }

    /// The note's own handle, carried over from the deck so the card stays the
    /// same object before and after it opens: a fixed 48 pt strip in the
    /// spine colour, the round close button on top, Float Note / Return to
    /// Deck under it, the title running down the rest. Floating, the note
    /// keeps its spine: it is still the same card, and the way back is on it.
    ///
    /// The stack stays centre-aligned: the rotated label has to sit in the
    /// middle of the strip. Only the buttons are pinned to the top, through an
    /// overlay, and the label is pushed down by the height of that zone so they
    /// never meet.
    private var spine: some View {
        ZStack {
            model.color.spineSwiftUI

            SpineLabel(
                text: model.displayTitle,
                color: model.color.inkSwiftUI.opacity(0.78),
                topInset: Self.closeZoneHeight
            )

            // The perforation between spine and paper.
            HStack {
                Spacer()
                PerforationLine(color: model.color.inkSwiftUI.opacity(0.28))
                    .padding(.vertical, 10)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: Self.buttonGap) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(model.color.inkSwiftUI.opacity(0.75))
                        .frame(width: Self.closeDiameter, height: Self.closeDiameter)
                        .background(Circle().fill(model.color.surfaceSwiftUI.opacity(0.7)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
                .accessibilityLabel("Close")

                floatButton
            }
            .padding(.top, Self.closeTopMargin)
        }
        .frame(width: EdgeMetrics.tabWidth)
        .contentShape(Rectangle())
        .gesture(windowDrag)
    }

    /// Float Note on an anchored note, Return to Deck on a floating one: a
    /// 22 pt disc in the ink colour with the glyph in the paper colour, so it
    /// reads as the one solid control on the spine. ⌥⌘P does the same.
    private var floatButton: some View {
        let floating = presentation == .detached
        return Button(action: onTogglePin) {
            Image(systemName: floating ? "arrow.right.to.line" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(model.color.surfaceSwiftUI)
                .frame(width: Self.closeDiameter, height: Self.closeDiameter)
                .background(Circle().fill(model.color.inkSwiftUI))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(floating ? "Return to Deck" : "Float Note")
        .accessibilityLabel(floating ? "Return to Deck" : "Float Note")
    }

    private static let closeDiameter: CGFloat = 22
    private static let closeTopMargin: CGFloat = 12
    private static let buttonGap: CGFloat = 8
    /// Vertical room reserved at the top of the spine for the two buttons.
    private static let closeZoneHeight: CGFloat = closeTopMargin + 2 * closeDiameter + buttonGap + 8

    private var content: some View {
        VStack(spacing: 0) {
            header
            if model.isFindBarVisible {
                findBar
            }
            NoteTextView(
                text: $model.text,
                color: model.color,
                findQuery: model.findQuery,
                findIndex: model.findIndex,
                isEditable: !model.isLocked
            )
            footer
        }
        .overlay(alignment: .bottomLeading) { tagSuggestions }
    }

    /// Opens upward from the tags field. It is a row count, not a fixed height,
    /// so on a short note the list shrinks instead of running off the top.
    private var tagSuggestions: some View {
        GeometryReader { proxy in
            if model.isTagListVisible {
                TagSuggestionList(
                    rows: model.tagRows,
                    selection: model.tagSelection,
                    color: model.color,
                    onAccept: { model.acceptTagRow(at: $0) },
                    onHover: { model.hoverTagRow($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 14)
                .padding(.bottom, footerHeight - 7)
            }
            Color.clear
                .allowsHitTesting(false)
                .onAppear { reportRoom(proxy.size.height) }
                .onChange(of: proxy.size.height) { reportRoom($0) }
                .onChange(of: footerHeight) { _ in reportRoom(proxy.size.height) }
        }
    }

    /// Rows that fit between the header and the tags field.
    private func reportRoom(_ height: CGFloat) {
        let fit = max(1, Int((height - footerHeight - 90) / TagSuggestionList.rowHeight))
        DispatchQueue.main.async { model.setTagRowLimit(fit) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Title", text: $model.title)
                .textFieldStyle(.plain)
                .disabled(model.isLocked)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.color.inkSwiftUI)

            // Re-evaluated every 30 s, so "5 min ago" keeps counting while the
            // note sits open.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(model.isLocked ? "Locked \u{00B7} read-only" : model.statusLabel(now: context.date))
                    .font(.system(size: 12))
                    .foregroundStyle(model.color.secondaryInkSwiftUI)
                    .lineLimit(1)
                    .fixedSize()
            }

            Button(action: onToggleCenterPin) {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.color.secondaryInkSwiftUI)
            .help(model.isPinned ? "Unpin from Center" : "Pin to Center")
            .accessibilityLabel(model.isPinned ? "Unpin from Center" : "Pin to Center")

            Button(action: onShowTools) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.color.secondaryInkSwiftUI)
            .help("Tools")

        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .gesture(windowDrag)
    }

    // MARK: - Find

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(model.color.inkSwiftUI.opacity(0.45))
            TextField("Find in note", text: $model.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($findFieldFocused)
                .onSubmit { model.advanceFind(by: 1) }

            if !model.findQuery.isEmpty {
                Text(model.matchCount == 0 ? "none" : "\(model.currentMatchNumber)/\(model.matchCount)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(model.color.inkSwiftUI.opacity(0.5))
                Button { model.advanceFind(by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                    .disabled(model.matchCount == 0)
                Button { model.advanceFind(by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                    .disabled(model.matchCount == 0)
            }

            Button { model.toggleFindBar() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(model.color.inkSwiftUI.opacity(0.6))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(model.color.spineSwiftUI.opacity(0.4))
    }

    // MARK: - Footer

    /// The five colours, always within reach — the note's colour is something
    /// people change while writing, not a setting they go looking for.
    ///
    /// The swatches are filled with each colour's *spine*, not its paper
    /// shade. Paper shades are pale by design and a row of them on a footer of
    /// the same family disappeared, especially the one already in use.
    private var colorRow: some View {
        HStack(spacing: 10) {
            ForEach(NoteColor.allCases, id: \.self) { color in
                let isSelected = color == model.color
                Button { model.setColor(color) } label: {
                    Circle()
                        .fill(color.spineSwiftUI)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.black.opacity(0.22), lineWidth: 1))
                        .overlay(
                            // A halo drawn outside the swatch, so the selected
                            // colour is legible even against its own note.
                            Circle()
                                .strokeBorder(model.color.inkSwiftUI.opacity(0.8), lineWidth: 2)
                                .padding(-3.5)
                                .opacity(isSelected ? 1 : 0)
                        )
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                }
                .buttonStyle(.plain)
                .help(color.displayName)
            }
        }
        .padding(.leading, 3)
        .animation(.easeOut(duration: 0.12), value: model.color)
    }

    /// Tags for the note, `#work #ideas`. Typing saves like the body does;
    /// Return tidies what was typed into that form. At rest the tags are chips;
    /// clicking them, or the empty field, brings back the text field.
    private var tagsRow: some View {
        let tags = TagText.parse(model.tagsText)
        let showChips = !model.isTagFieldFocused && !tags.isEmpty
        return HStack(spacing: 6) {
            if !showChips {
                Image(systemName: "number")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(model.color.secondaryInkSwiftUI)
            }
            ZStack(alignment: .leading) {
                TagField(
                    text: $model.tagsText,
                    model: model,
                    ink: model.color.ink,
                    isEnabled: !model.isLocked
                )
                .frame(height: 20)
                .opacity(showChips ? 0 : 1)

                if showChips {
                    TagChips(tags: tags, color: model.color) { tag in
                        if DailyNotes.isReserved(tag) { onDailyChip() } else { model.tagField?.focus() }
                    }
                        .contentShape(Rectangle())
                        .onTapGesture { model.tagField?.focus() }
                }
            }
            if let line = model.deckLine {
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(model.color.secondaryInkSwiftUI)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .frame(height: 22)
    }

    private var footer: some View {
        VStack(spacing: 7) {
            tagsRow
            footerControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack(alignment: .top) {
                model.color.surfaceSwiftUI
                Rectangle()
                    .fill(model.color.inkSwiftUI.opacity(0.12))
                    .frame(height: 1)
            }
        )
        .background(GeometryReader { proxy in
            Color.clear.onAppear { footerHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { footerHeight = $0 }
        })
    }

    private var footerControls: some View {
        HStack(spacing: 10) {
            colorRow

            Spacer(minLength: 8)

            // Anchored, the footer carries the colours and the way out. Lifted
            // off the edge, the note has to carry everything.
            if presentation == .detached {
                Button("Delete", action: onDelete)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .foregroundStyle(Color(nsColor: NSColor(srgbRed: 0.80, green: 0.24, blue: 0.22, alpha: 1)))

                Button(model.state == .archived ? "Reopen" : "Mark complete") {
                    model.toggleComplete()
                }
                .buttonStyle(NoteFooterButtonStyle(color: model.color))

                Button("Close", action: onClose)
                    .buttonStyle(NoteFooterButtonStyle(color: model.color))
            }
        }
        .font(.system(size: 11.5))
    }
}

private struct NoteFooterButtonStyle: ButtonStyle {
    let color: NoteColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.surfaceSwiftUI.opacity(configuration.isPressed ? 0.6 : 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.black.opacity(0.10), lineWidth: 1)
            )
            .foregroundStyle(color.inkSwiftUI.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The note's tags as chips in the spine colour.
private struct TagChips: View {
    let tags: [String]
    let color: NoteColor
    /// A chip was clicked. The field takes the click, except on `daily`.
    var onTag: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text("#" + tag)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(color.inkSwiftUI)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.spineSwiftUI))
                    .contentShape(Capsule())
                    .onTapGesture { onTag(tag) }
                    .help(DailyNotes.isReserved(tag) ? "Earlier dailies" : "Edit tags")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
