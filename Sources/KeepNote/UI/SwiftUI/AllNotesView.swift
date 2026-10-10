import SwiftUI

/// Actions All Notes hands back to the app. Keeping them as closures means the
/// view never reaches for a window, a panel or an `NSSavePanel` itself.
struct NoteListActions {
    var open: (UUID) -> Void
    var newNote: () -> Void
    var archive: ([UUID]) -> Void
    var unarchive: ([UUID]) -> Void
    var delete: ([UUID]) -> Void
    var export: ([UUID]) -> Void
    var openSettings: () -> Void = {}
    /// Edit Daily Template…, from the Daily list.
    var editDailyTemplate: () -> Void = {}
    /// Keep on Deck on or off for these notes.
    var setKeepOnDeck: ([UUID], Bool) -> Void = { _, _ in }
    /// Pin to Center on or off for these notes.
    var setPinned: ([UUID], Bool) -> Void = { _, _ in }
    /// Rename Tag…: asks for the name (and about a merge); returns the name the
    /// tag ended up with, or `nil` if nothing changed.
    var renameTag: (String) -> String? = { _ in nil }
    /// Delete Tag…: asks first.
    var deleteTag: (String) -> Void = { _ in }
    var newNoteWithTag: (String) -> Void = { _ in }
    /// Add Tag… / Remove Tag… on several notes: ask which tag, then apply.
    var addTagToNotes: ([UUID]) -> Void = { _ in }
    var removeTagFromNotes: ([UUID]) -> Void = { _ in }
    /// Notes dropped on a tag in the sidebar get that tag.
    var tagNotes: (String, [UUID]) -> Void = { _, _ in }
}

/// The full list: a sidebar of libraries and tags, the notes in the selected
/// one (searchable within it), multiple selection and a reading pane.
struct AllNotesView: View {
    @ObservedObject var store: NoteStore
    var actions: NoteListActions

    @State private var query = ""
    /// The sidebar's selection: a library, a tag or Untagged. Kept between
    /// openings in `AppSettings.allNotesSelection`.
    @State private var sidebarSelection: NoteSelection
    @State private var selection: Set<UUID> = []
    /// The Daily introduction has been dismissed with "Got it".
    @State private var introSeen = AppSettings.shared.dailyIntroSeen

    init(store: NoteStore, actions: NoteListActions, initialSidebar: NoteSelection? = nil,
         initialSelection: Set<UUID> = []) {
        self.store = store
        self.actions = actions
        let stored = AppSettings.shared.allNotesSelection.flatMap(NoteSelection.init(storageValue:))
        _sidebarSelection = State(initialValue: initialSidebar ?? stored ?? .default)
        _selection = State(initialValue: initialSelection)
    }

    private var index: TagLibrary.Index { TagLibrary.index(store.notes) }

    private var results: [Note] {
        TagLibrary.filter(store.search(query), by: sidebarSelection)
            .sorted { $0.editedAt > $1.editedAt }
    }

    private var selectedNotes: [Note] {
        results.filter { selection.contains($0.id) }
    }

    private var isDailyList: Bool { sidebarSelection == .library(.daily) }

    /// The template's fixed row tops the Daily list — except while searching:
    /// it is not a note, so no search finds it.
    private var showsTemplateRow: Bool { isDailyList && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var templateSelected: Bool { showsTemplateRow && selection.contains(DailyTemplatePane.rowID) }

    /// Clicking a tag on a note selects it in the sidebar. The reserved tag
    /// is the Daily shelf.
    private func showTag(_ tag: String) {
        if DailyNotes.isReserved(tag) {
            sidebarSelection = .library(.daily)
            return
        }
        sidebarSelection = .tag(index.entry(named: tag)?.name ?? tag)
    }

    var body: some View {
        NavigationSplitView {
            AllNotesSidebar(
                index: index,
                selection: $sidebarSelection,
                onRename: renameTag,
                onDelete: actions.deleteTag,
                onNewNote: actions.newNoteWithTag,
                onDropNotes: actions.tagNotes,
                onEditDailyTemplate: actions.editDailyTemplate
            )
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            noteList
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
        } detail: {
            detail
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search \(sidebarSelection.title)")
        .toolbar { toolbarContent }
        .frame(minWidth: 900, minHeight: 480)
        .onChange(of: sidebarSelection) { newValue in
            AppSettings.shared.allNotesSelection = newValue.storageValue
            selection.removeAll()
        }
        .onAppear(perform: dropMissingTag)
        .onChange(of: index.tags.map(\.name)) { _ in dropMissingTag() }
        // "Show All Dailies" and the like, while the window is already open.
        .onReceive(NotificationCenter.default.publisher(for: .keepNoteShowNotesSelection)) { note in
            if let value = note.userInfo?["selection"] as? String, let wanted = NoteSelection(storageValue: value) {
                sidebarSelection = wanted
                // Changing the list clears the selection, so the template is
                // selected a beat later.
                if note.userInfo?["template"] as? Bool == true {
                    DispatchQueue.main.async { selection = [DailyTemplatePane.rowID] }
                }
            }
        }
    }

    /// A renamed tag that was selected stays selected under its new name.
    private func renameTag(_ name: String) {
        guard let renamed = actions.renameTag(name) else { return }
        if case .tag(let selected) = sidebarSelection, TagText.fold(selected) == TagText.fold(name) {
            sidebarSelection = .tag(renamed)
        }
    }

    /// A selected tag that no note carries any more (renamed, deleted, or gone
    /// with its last note) falls back to All Notes.
    private func dropMissingTag() {
        if case .tag(let name) = sidebarSelection, index.entry(named: name) == nil {
            sidebarSelection = .default
        }
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            listHeader
            if isDailyList && !introSeen {
                DailyIntro {
                    AppSettings.shared.dailyIntroSeen = true
                    introSeen = true
                }
            }
            Divider()
            if isDailyList && results.isEmpty && query.isEmpty && !showsTemplateRow {
                DailyEmptyState()
            } else {
                dayOrFlatList
            }
        }
    }

    private var dayOrFlatList: some View {
        List(selection: $selection) {
            if showsTemplateRow {
                DailyTemplateRow()
                    .tag(DailyTemplatePane.rowID)
            }
            if isDailyList {
                // Day by day, the latest day first.
                ForEach(DailyNotes.groups(results), id: \.day) { group in
                    Section {
                        ForEach(group.items) { noteRow($0) }
                    } header: {
                        DayHeader(day: group.day)
                    }
                }
            } else {
                ForEach(results) { noteRow($0) }
            }
        }
        .listStyle(.inset)
        // Right-clicking inside the selection acts on all of it; on a row
        // outside it, on that row alone. Double-click opens.
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            ids.subtracting([DailyTemplatePane.rowID]).forEach(actions.open)
        }
        .onDeleteCommand {
            let notes = selection.subtracting([DailyTemplatePane.rowID])
            guard !notes.isEmpty else { return }
            actions.delete(Array(notes))
            selection.removeAll()
        }
    }

    private func noteRow(_ note: Note) -> some View {
        NoteRow(note: note, onTag: showTag)
            .tag(note.id)
            .onDrag {
                // Dragging a selected row takes the whole selection.
                let ids = selection.contains(note.id)
                    ? results.map(\.id).filter(selection.contains)
                    : [note.id]
                return NSItemProvider(object: NoteDragPayload.encode(ids) as NSString)
            }
    }

    /// The selection's name and how many notes it shows.
    private var listHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(sidebarSelection.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if isDailyList {
                Button("Edit Template\u{2026}") { selection = [DailyTemplatePane.rowID] }
                    .controlSize(.small)
                    .help("Edit the text new daily notes start from")
            }
            Text(countLabel)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var countLabel: String {
        let total = results.count
        let notes = "\(total) note\(total == 1 ? "" : "s")"
        return selectedNotes.count > 1 ? "\(selectedNotes.count) of \(notes)" : notes
    }

    @ViewBuilder
    private var detail: some View {
        if templateSelected && selectedNotes.isEmpty {
            DailyTemplatePane(store: store)
        } else if selectedNotes.count == 1, let note = selectedNotes.first {
            NoteReadingPane(note: note, store: store, actions: actions, onTag: showTag)
                .id(note.id)
        } else if selectedNotes.count > 1 {
            MultipleSelectionPane(notes: selectedNotes, actions: actions) {
                selection.removeAll()
            }
        } else {
            ContentUnavailablePlaceholder()
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let notes = store.notes.filter { ids.contains($0.id) }
        if notes.count == 1, let note = notes.first {
            Button("Open") { actions.open(note.id) }
            Divider()
            pinToggle(for: [note])
            keepToggle(for: [note])
            if note.state == .archived {
                Button("Move to Deck") { actions.unarchive([note.id]) }
            } else {
                Button("Archive") { actions.archive([note.id]) }
            }
            Button("Export\u{2026}") { actions.export([note.id]) }
            Divider()
            Button("Delete", role: .destructive) { actions.delete([note.id]) }
        } else if notes.count > 1 {
            let idList = notes.map(\.id)
            pinToggle(for: notes)
            keepToggle(for: notes)
            if notes.allSatisfy({ $0.state == .archived }) {
                Button("Move \(notes.count) Notes to Deck") { actions.unarchive(idList) }
            } else {
                Button("Archive \(notes.count) Notes") { actions.archive(idList) }
            }
            Button("Export \(notes.count) Notes\u{2026}") { actions.export(idList) }
            Divider()
            Button("Add Tag\u{2026}") { actions.addTagToNotes(idList) }
            Button("Remove Tag\u{2026}") { actions.removeTagFromNotes(idList) }
                .disabled(notes.allSatisfy { $0.tags.isEmpty })
            Divider()
            Button("Delete \(notes.count) Notes", role: .destructive) {
                actions.delete(idList)
                selection.subtract(ids)
            }
        }
    }

    /// The Pin to Center entry, ticked when every one of `notes` is pinned.
    /// Archived notes are not on the deck, so there is nothing to pin.
    private func pinToggle(for notes: [Note]) -> some View {
        let ids = notes.map(\.id)
        let all = notes.allSatisfy(\.isPinned)
        return Toggle("Pin to Center", isOn: Binding(get: { all }, set: { actions.setPinned(ids, $0) }))
            .disabled(notes.contains { $0.state == .archived })
    }

    /// The Keep on Deck entry, ticked when every one of `notes` has it.
    private func keepToggle(for notes: [Note]) -> some View {
        let ids = notes.map(\.id)
        let all = notes.allSatisfy(\.keepOnDeck)
        return Toggle("Keep on Deck", isOn: Binding(get: { all }, set: { actions.setKeepOnDeck(ids, $0) }))
    }

    /// Search (inside the current selection), New Note and Settings. Archive,
    /// export and delete live with the notes: the reading pane, the context
    /// menu and the multiple-selection pane.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: actions.newNote) {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .help("New note")

            Button(action: actions.openSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }
}

/// Library, then Tags and Untagged. Each row carries its count.
struct AllNotesSidebar: View {
    let index: TagLibrary.Index
    @Binding var selection: NoteSelection
    var onRename: (String) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }
    var onNewNote: (String) -> Void = { _ in }
    var onDropNotes: (String, [UUID]) -> Void = { _, _ in }
    var onEditDailyTemplate: () -> Void = {}

    /// The tag row notes are being dragged over.
    @State private var dropTarget: String?

    var body: some View {
        List(selection: Binding<NoteSelection?>(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )) {
            Section("Library") {
                ForEach(NoteLibrary.allCases, id: \.self) { library in
                    SidebarRow(count: index.count(of: library)) {
                        Label(library.title, systemImage: library.symbolName)
                    }
                    .tag(NoteSelection.library(library))
                    .contextMenu {
                        if library == .daily {
                            Button("Edit Daily Template\u{2026}", action: onEditDailyTemplate)
                        }
                    }
                }
            }
            Section("Tags") {
                // The reserved tag has no row of its own here.
                ForEach(index.tags.filter { !DailyNotes.isReserved($0.name) }, id: \.name) { entry in
                    SidebarRow(count: entry.count) {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Image(systemName: "number")
                        }
                    }
                    .tag(NoteSelection.tag(entry.name))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(dropTarget == entry.name ? 0.25 : 0))
                            .padding(.horizontal, 8)
                    )
                    .onDrop(of: [.utf8PlainText], isTargeted: Binding(
                        get: { dropTarget == entry.name },
                        set: { inside in
                            if inside { dropTarget = entry.name } else if dropTarget == entry.name { dropTarget = nil }
                        }
                    )) { providers in
                        drop(providers, on: entry.name)
                    }
                    .contextMenu {
                        Button("Rename Tag\u{2026}") { onRename(entry.name) }
                        Button("New Note with Tag") { onNewNote(entry.name) }
                        Divider()
                        Button("Delete Tag\u{2026}", role: .destructive) { onDelete(entry.name) }
                    }
                }
                SidebarRow(count: index.untagged) {
                    Label("Untagged", systemImage: "tag.slash")
                }
                .tag(NoteSelection.untagged)
            }
        }
        .listStyle(.sidebar)
    }

    private func drop(_ providers: [NSItemProvider], on tag: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let ids = NoteDragPayload.decode(text)
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async { onDropNotes(tag, ids) }
        }
        return true
    }
}

/// The fixed row at the top of the Daily list that stands for the daily
/// template. Not a note: it is no part of any count, search, tag or list.
private struct DailyTemplateRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(DailyTemplateEditorView.title)
                    .font(.system(size: 13, weight: .medium))
                Text("Where new daily notes start")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// The heading of one day in the Daily list: "Today", "Yesterday", or the
/// date in full, in the system's language.
private struct DayHeader: View {
    let day: DailyDay

    var body: some View {
        Text(day.date().map { Self.formatter.string(from: $0) } ?? day.string)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// Shown above the Daily list until "Got it" is pressed, once.
struct DailyIntro: View {
    static let text = "Daily notes. Add the daily tag to any note, as many as you like per day. Notes from your two most recent days stay on the deck. Older ones are archived automatically and kept here. You can set a template for new daily notes."

    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 0)
                Button("Got it", action: onDismiss)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
    }
}

private struct DailyEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No daily notes yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Add the daily tag to a note, or use Today\u{2019}s Daily.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarRow<Title: View>: View {
    let count: Int
    @ViewBuilder var title: Title

    var body: some View {
        HStack {
            title
                .lineLimit(1)
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// A note's tags as chips in its spine colour, each one a button that selects
/// the tag in the sidebar. The chip colours are the note's palette, so they
/// read the same in light and dark.
struct TagChipLinks: View {
    let tags: [String]
    let color: NoteColor
    var size: CGFloat = 10.5
    var onTag: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(color.inkSwiftUI)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(color.spineSwiftUI))
                    .contentShape(Capsule())
                    .onTapGesture { onTag(tag) }
                    .help("Show notes tagged #\(tag)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// One note in the list: a 4 pt bar in the spine colour, the title, one line
/// of preview, the date and the tags.
private struct NoteRow: View {
    let note: Note
    var onTag: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(note.color.spineSwiftUI)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if note.isDaily {
                        Image(systemName: "calendar")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .help("Daily note")
                    }
                    if note.state == .archived {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help(DeckStatus.archivedLine(for: note) ?? "Archived")
                    }
                    Spacer(minLength: 4)
                    Text(Self.formatter.localizedString(for: note.editedAt, relativeTo: Date()))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(note.preview.isEmpty ? " " : note.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !note.tags.isEmpty {
                    TagChipLinks(tags: note.tags, color: note.color, size: 10, onTag: onTag)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// One note, read: its dates and the Open, Archive and Export buttons in the
/// window's own colours, then the note as it looks open — spine, perforation,
/// paper — with its tags and "Add tag" at the foot of the paper.
struct NoteReadingPane: View {
    let note: Note
    let store: NoteStore
    let actions: NoteListActions
    var onTag: (String) -> Void

    @StateObject private var model: NoteEditorModel

    init(note: Note, store: NoteStore, actions: NoteListActions, onTag: @escaping (String) -> Void) {
        self.note = note
        self.store = store
        self.actions = actions
        self.onTag = onTag
        let model = NoteEditorModel(note: note, store: store)
        model.savesTagsOnly = true
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoBar
            NoteReadingCard(note: note, model: model, onTag: onTag)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        }
        .padding(16)
        .onReceive(store.changes) { _ in model.refreshFromStore() }
        .onDisappear { model.flush() }
    }

    private var infoBar: some View {
        HStack(spacing: 8) {
            Text("Created \(Self.day.string(from: note.createdAt)) \u{00B7} Edited \(Self.day.string(from: note.editedAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Created \(Self.formatter.string(from: note.createdAt))\nEdited \(Self.formatter.string(from: note.editedAt))")
            Spacer(minLength: 8)
            Button("Open") { actions.open(note.id) }
                .keyboardShortcut(.defaultAction)
            Toggle("Pin to Center", isOn: Binding(get: { note.isPinned }, set: { actions.setPinned([note.id], $0) }))
                .toggleStyle(.checkbox)
                .disabled(note.state == .archived)
            Toggle("Keep on Deck", isOn: Binding(get: { note.keepOnDeck }, set: { actions.setKeepOnDeck([note.id], $0) }))
                .toggleStyle(.checkbox)
            if note.state == .archived {
                Button("Move to Deck") { actions.unarchive([note.id]) }
            } else {
                Button("Archive") { actions.archive([note.id]) }
            }
            Button("Export\u{2026}") { actions.export([note.id]) }
        }
        .controlSize(.small)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// The paper part of the reading pane. Its colours are the note's palette
/// and stay the same in light and dark.
private struct NoteReadingCard: View {
    let note: Note
    @ObservedObject var model: NoteEditorModel
    var onTag: (String) -> Void

    /// "Add tag" was clicked: the tags field shows instead of the chips until
    /// it loses focus.
    @State private var isAddingTag = false
    @State private var footerHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            spine
            paper
        }
        .background(note.color.surfaceSwiftUI)
    }

    private var spine: some View {
        ZStack {
            note.color.spineSwiftUI
            SpineLabel(text: note.displayTitle, color: note.color.inkSwiftUI.opacity(0.78), topInset: 4)
            HStack {
                Spacer()
                PerforationLine(color: note.color.inkSwiftUI.opacity(0.28))
                    .padding(.vertical, 10)
            }
        }
        .frame(width: EdgeMetrics.tabWidth)
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(note.displayTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(note.color.inkSwiftUI)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            NoteTextView(text: .constant(note.body), color: note.color, findQuery: "", findIndex: 0, isEditable: false)
            footer
        }
        .overlay(alignment: .bottomLeading) { suggestions }
    }

    private var showsField: Bool { isAddingTag || model.isTagFieldFocused }

    private var footer: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                TagField(text: $model.tagsText, model: model, ink: note.color.ink, isEnabled: !note.isLocked)
                    .frame(height: 20)
                    .opacity(showsField ? 1 : 0)
                    .allowsHitTesting(showsField)
                if !showsField {
                    HStack(spacing: 8) {
                        if !note.tags.isEmpty {
                            TagChipLinks(tags: note.tags, color: note.color, size: 11, onTag: onTag)
                                .fixedSize()
                        }
                        if !note.isLocked {
                            Button(action: startAddingTag) {
                                Label("Add tag", systemImage: "plus")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(note.color.secondaryInkSwiftUI)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            if let line = DeckStatus.line(for: note) {
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(note.color.secondaryInkSwiftUI)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            ZStack(alignment: .top) {
                note.color.surfaceSwiftUI
                Rectangle().fill(note.color.inkSwiftUI.opacity(0.12)).frame(height: 1)
            }
        )
        .background(GeometryReader { proxy in
            Color.clear.onAppear { footerHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { footerHeight = $0 }
        })
        .onChange(of: model.isTagFieldFocused) { focused in
            guard !focused else { return }
            isAddingTag = false
            model.tidyTags()
            model.flush()
        }
    }

    /// The field opens with the note's tags in it and the caret after them,
    /// ready for a new one; the suggestion list is the open note's.
    private func startAddingTag() {
        isAddingTag = true
        model.setTagRowLimit(6)
        DispatchQueue.main.async {
            let current = TagText.format(TagText.parse(model.tagsText))
            let text = current.isEmpty ? "" : current + " "
            model.tagField?.focus()
            model.tagField?.apply(text: text, caret: (text as NSString).length)
        }
    }

    private var suggestions: some View {
        Group {
            if model.isTagListVisible {
                TagSuggestionList(
                    rows: model.tagRows,
                    selection: model.tagSelection,
                    color: note.color,
                    onAccept: { model.acceptTagRow(at: $0) },
                    onHover: { model.hoverTagRow($0) }
                )
                .padding(.leading, 14)
                .padding(.bottom, footerHeight - 7)
            }
        }
    }
}

private struct MultipleSelectionPane: View {
    let notes: [Note]
    let actions: NoteListActions
    var onClear: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("\(notes.count) notes selected")
                .font(.system(size: 15, weight: .medium))
            HStack(spacing: 10) {
                Button("Export\u{2026}") { actions.export(notes.map(\.id)) }
                if notes.allSatisfy({ $0.state == .archived }) {
                    Button("Move to Stack") { actions.unarchive(notes.map(\.id)) }
                } else {
                    Button("Archive") { actions.archive(notes.map(\.id)) }
                }
                Button("Delete", role: .destructive) {
                    actions.delete(notes.map(\.id))
                    onClear()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Select a note to read it here")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
