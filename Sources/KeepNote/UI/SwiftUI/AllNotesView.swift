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
    /// The note in the pane now, or `nil`: selecting a note opens it, for the
    /// time rule as for everything else.
    var select: (UUID?) -> Void = { _ in }
    /// Move to Group › for these notes: a group, or none.
    var moveToGroup: ([UUID], UUID?) -> Void = { _, _ in }
    /// Move to Group › New Group…: asks for the name, then moves them in.
    var newGroupWithNotes: ([UUID]) -> Void = { _ in }
    /// The sidebar's Groups: New Group…, Rename Group…, Delete Group… (asks
    /// first), a colour, and the order.
    var createGroup: () -> Void = {}
    var renameGroup: (UUID) -> Void = { _ in }
    var deleteGroup: (UUID) -> Void = { _ in }
    var setGroupColor: (UUID, GroupColor) -> Void = { _, _ in }
    var reorderGroups: ([UUID]) -> Void = { _ in }
}

/// The full list: a sidebar of libraries and tags, the notes in the selected
/// one (searchable within it), multiple selection and a pane that edits the
/// selected note.
struct AllNotesView: View {
    @ObservedObject var store: NoteStore
    /// The list's order, from the toolbar.
    @ObservedObject var settings: AppSettings = .shared
    var actions: NoteListActions

    @State private var query = ""
    /// The sidebar's selection: a library, a tag or Untagged. Kept between
    /// openings in `AppSettings.allNotesSelection`.
    @State private var sidebarSelection: NoteSelection
    @State private var selection: Set<UUID> = []
    /// The sidebar and the list, or the pane alone over the whole window.
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The Daily introduction has been dismissed with "Got it".
    @State private var introSeen = AppSettings.shared.dailyIntroSeen

    /// A note just made here: the pane puts the caret in its title.
    @State private var titleFocus: UUID?
    /// ↑ ↓ in the list, Return into the note, Esc back.
    @StateObject private var keyboard = AllNotesKeyboard()

    init(store: NoteStore, actions: NoteListActions, initialSidebar: NoteSelection? = nil,
         initialSelection: Set<UUID> = [], focusTitleOf: UUID? = nil) {
        self.store = store
        self.actions = actions
        let stored = AppSettings.shared.allNotesSelection.flatMap(NoteSelection.init(storageValue:))
        _sidebarSelection = State(initialValue: initialSidebar ?? stored ?? .default)
        _selection = State(initialValue: initialSelection)
        _titleFocus = State(initialValue: focusTitleOf)
    }

    private var index: TagLibrary.Index { TagLibrary.index(store.notes) }

    private var results: [Note] {
        settings.allNotesSort.sorted(GroupLibrary.filter(store.search(query), by: sidebarSelection, groups: store.groups))
    }

    /// What the list is called: a group by its name.
    private var selectionTitle: String {
        if case .group(let id) = sidebarSelection { return store.group(id: id)?.name ?? sidebarSelection.title }
        return sidebarSelection.title
    }

    private var selectedNotes: [Note] {
        results.filter { selection.contains($0.id) }
    }

    private var isDailyList: Bool { sidebarSelection == .library(.daily) }

    /// The one note the pane is editing, if it is editing one.
    private var paneNoteID: UUID? {
        let notes = selectedNotes
        return notes.count == 1 ? notes[0].id : nil
    }

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
        splitView.followsTextSize()
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            AllNotesSidebar(
                index: index,
                groups: store.groups,
                groupCounts: GroupLibrary.counts(store.notes.filter { !DailyNotes.hasTag($0.tags) }, groups: store.groups),
                actions: actions,
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
        .searchable(text: $query, placement: .toolbar, prompt: L("Search %@", selectionTitle))
        .toolbar { toolbarContent }
        .frame(minWidth: 900, minHeight: 480)
        .onChange(of: sidebarSelection) { newValue in
            AppSettings.shared.allNotesSelection = newValue.storageValue
            selection.removeAll()
        }
        .onAppear {
            dropMissingTag()
            actions.select(paneNoteID)
        }
        .onChange(of: paneNoteID) { actions.select($0) }
        .onAppear { keyboard.hasSingleNote = { [weak keyboard] in keyboard?.pane != nil } }
        .onChange(of: index.tags.map(\.name)) { _ in dropMissingTag() }
        .onChange(of: store.groups.map(\.id)) { _ in dropMissingGroup() }
        // "Show All Dailies" and the like, while the window is already open.
        .onReceive(NotificationCenter.default.publisher(for: .keepNoteShowNotesSelection)) { note in
            if let value = note.userInfo?["selection"] as? String, let wanted = NoteSelection(storageValue: value) {
                let made = (note.userInfo?["note"] as? String).flatMap(UUID.init(uuidString:))
                // A new note matches no search: the search goes so it shows.
                if made != nil { query = "" }
                sidebarSelection = wanted
                // Changing the list clears the selection, so the template, or
                // the note just made, is selected a beat later.
                if note.userInfo?["template"] as? Bool == true {
                    DispatchQueue.main.async { selection = [DailyTemplatePane.rowID] }
                } else if let made {
                    DispatchQueue.main.async {
                        titleFocus = made
                        selection = [made]
                    }
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
                    .background(AllNotesListAnchor(keyboard: keyboard))
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
                        ForEach(settings.allNotesSort.sorted(group.items)) { noteRow($0) }
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

    /// A selected group that was deleted falls back to All Notes.
    private func dropMissingGroup() {
        if case .group(let id) = sidebarSelection, store.group(id: id) == nil { sidebarSelection = .default }
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
            Text(selectionTitle)
                .scaledFont(15, weight: .semibold)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isDailyList {
                Button(L("Edit Template\u{2026}")) { selection = [DailyTemplatePane.rowID] }
                    .controlSize(.small)
                    .help(L("Edit the text new daily notes start from"))
            }
            Text(countLabel)
                .scaledFont(11.5, monospacedDigit: true)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var countLabel: String {
        let total = results.count
        let notes = TagLibrary.notesPhrase(total)
        return selectedNotes.count > 1 ? L("%d of %@", selectedNotes.count, notes) : notes
    }

    @ViewBuilder
    private var detail: some View {
        if templateSelected && selectedNotes.isEmpty {
            DailyTemplatePane(store: store)
        } else if selectedNotes.count == 1, let note = selectedNotes.first {
            NoteReadingPane(note: note, store: store, actions: actions, onTag: showTag,
                            focusTitle: titleFocus == note.id, keyboard: keyboard) { titleFocus = nil }
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
            Button(L("Open")) { actions.open(note.id) }
            Divider()
            pinToggle(for: [note])
            keepToggle(for: [note])
            if note.state == .archived {
                Button(L("Move to Deck")) { actions.unarchive([note.id]) }
            } else {
                Button(L("Archive")) { actions.archive([note.id]) }
            }
            Button(L("Export\u{2026}")) { actions.export([note.id]) }
            moveToGroupMenu(for: [note])
            Divider()
            Button(L("Delete"), role: .destructive) { actions.delete([note.id]) }
        } else if notes.count > 1 {
            let idList = notes.map(\.id)
            pinToggle(for: notes)
            keepToggle(for: notes)
            if notes.allSatisfy({ $0.state == .archived }) {
                Button(L("Move %d Notes to Deck", notes.count)) { actions.unarchive(idList) }
            } else {
                Button(L("Archive %d Notes", notes.count)) { actions.archive(idList) }
            }
            Button(L("Export %d Notes\u{2026}", notes.count)) { actions.export(idList) }
            Divider()
            Button(L("Add Tag\u{2026}")) { actions.addTagToNotes(idList) }
            Button(L("Remove Tag\u{2026}")) { actions.removeTagFromNotes(idList) }
                .disabled(notes.allSatisfy { $0.tags.isEmpty })
            moveToGroupMenu(for: notes)
            Divider()
            Button(L("Delete %d Notes", notes.count), role: .destructive) {
                actions.delete(idList)
                selection.subtract(ids)
            }
        }
    }

    /// Move to Group ›: No Group, each group (ticked when all of `notes` are in
    /// it), New Group…. A daily belongs to Daily and is not moved.
    private func moveToGroupMenu(for notes: [Note]) -> some View {
        let ids = notes.map(\.id)
        let common = Set(notes.map(\.groupID)).count == 1 ? notes.first?.groupID : nil
        return Menu(L("Move to Group")) {
            Toggle(L("No Group"), isOn: Binding(get: { common == nil && notes.allSatisfy { $0.groupID == nil } },
                                                set: { _ in actions.moveToGroup(ids, nil) }))
            if !store.groups.isEmpty { Divider() }
            ForEach(store.groups) { group in
                Toggle(isOn: Binding(get: { common == group.id }, set: { _ in actions.moveToGroup(ids, group.id) })) {
                    Label { Text(group.name) } icon: { Image(nsImage: GroupMenu.swatch(group.color)) }
                }
            }
            Divider()
            Button(L("New Group\u{2026}")) { actions.newGroupWithNotes(ids) }
        }
        .disabled(notes.allSatisfy(\.isDaily))
    }

    /// The Pin to Center entry, ticked when every one of `notes` is pinned.
    /// Archived notes are not on the deck, so there is nothing to pin.
    private func pinToggle(for notes: [Note]) -> some View {
        let ids = notes.map(\.id)
        let all = notes.allSatisfy(\.isPinned)
        return Toggle(L("Pin to Center"), isOn: Binding(get: { all }, set: { actions.setPinned(ids, $0) }))
            .disabled(notes.contains { $0.state == .archived })
    }

    /// The Keep on Deck entry, ticked when every one of `notes` has it.
    private func keepToggle(for notes: [Note]) -> some View {
        let ids = notes.map(\.id)
        let all = notes.allSatisfy(\.keepOnDeck)
        return Toggle(L("Keep on Deck"), isOn: Binding(get: { all }, set: { actions.setKeepOnDeck(ids, $0) }))
    }

    private var paneFillsWindow: Bool { columns == .detailOnly }

    /// The same button hides the sidebar and the list and brings them back.
    private func toggleFullPane() {
        columns = paneFillsWindow ? .all : .detailOnly
    }

    /// Search (inside the current selection), New Note, Settings and the
    /// button that gives the pane the whole window. Archive,
    /// export and delete live with the notes: the reading pane, the context
    /// menu and the multiple-selection pane.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker(L("Sort By"), selection: $settings.allNotesSort) {
                    ForEach(NoteSort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(L("Sort By"), systemImage: "arrow.up.arrow.down")
            }
            .help(L("Sort by %@", settings.allNotesSort.title))
        }
        ToolbarItem {
            Button(action: actions.newNote) {
                Label(L("New Note"), systemImage: "square.and.pencil")
            }
            .help(L("New note"))
        }
        ToolbarItem {
            Button(action: actions.openSettings) {
                Label(L("Settings"), systemImage: "gearshape")
            }
            .help(L("Settings"))
        }
        ToolbarItem {
            Button(action: toggleFullPane) {
                Label(paneFillsWindow ? L("Show Sidebar and List") : L("Hide Sidebar and List"),
                      systemImage: paneFillsWindow ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help(paneFillsWindow ? L("Show the sidebar and the list again") : L("Write with the note filling the window"))
        }
    }
}

/// Library, then Tags and Untagged. Each row carries its count.
struct AllNotesSidebar: View {
    let index: TagLibrary.Index
    var groups: [NoteGroup] = []
    /// How many notes each group holds, and how many are in none (dailies not
    /// counted: they are in Daily).
    var groupCounts = GroupLibrary.Counts(byGroup: [:], ungrouped: 0)
    var actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in }, delete: { _ in }, export: { _ in })
    @Binding var selection: NoteSelection
    var onRename: (String) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }
    var onNewNote: (String) -> Void = { _ in }
    var onDropNotes: (String, [UUID]) -> Void = { _, _ in }
    var onEditDailyTemplate: () -> Void = {}

    /// The tag row notes are being dragged over.
    @State private var dropTarget: String?
    /// The group row notes are being dragged over.
    @State private var groupDropTarget: UUID?

    var body: some View {
        List(selection: Binding<NoteSelection?>(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )) {
            Section(L("Library")) {
                // Daily is listed among the groups.
                ForEach(NoteLibrary.allCases.filter { $0 != .daily }, id: \.self) { library in
                    SidebarRow(count: index.count(of: library)) {
                        Label(library.title, systemImage: library.symbolName)
                    }
                    .tag(NoteSelection.library(library))
                    .contextMenu {
                        if library == .daily {
                            Button(L("Edit Daily Template\u{2026}"), action: onEditDailyTemplate)
                        }
                    }
                }
            }
            Section {
                // Daily is a group of its own, fixed: it has no menu to rename
                // or delete it, and notes cannot be dropped on it.
                SidebarRow(count: index.daily) {
                    Label(L("Daily"), systemImage: "calendar")
                }
                .tag(NoteSelection.library(.daily))
                .contextMenu {
                    Button(L("Edit Daily Template\u{2026}"), action: onEditDailyTemplate)
                }
                ForEach(groups) { group in
                    SidebarRow(count: groupCounts.count(of: group.id)) {
                        Label { Text(group.name) } icon: { Image(nsImage: GroupMenu.swatch(group.color, size: 12)) }
                    }
                    .tag(NoteSelection.group(group.id))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor.opacity(groupDropTarget == group.id ? 0.25 : 0))
                            .padding(.horizontal, 8)
                    )
                    .onDrop(of: [.utf8PlainText], isTargeted: Binding(
                        get: { groupDropTarget == group.id },
                        set: { inside in
                            if inside { groupDropTarget = group.id } else if groupDropTarget == group.id { groupDropTarget = nil }
                        }
                    )) { providers in
                        dropNotes(providers) { actions.moveToGroup($0, group.id) }
                    }
                    .contextMenu { groupMenu(group) }
                    .accessibilityAction(named: L("Rename Group\u{2026}")) { actions.renameGroup(group.id) }
                    .accessibilityAction(named: L("Delete Group\u{2026}")) { actions.deleteGroup(group.id) }
                }
                .onMove { source, destination in
                    var ids = groups.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    actions.reorderGroups(ids)
                }
                SidebarRow(count: groupCounts.ungrouped) {
                    Label(L("No Group"), systemImage: "tray")
                }
                .tag(NoteSelection.noGroup)
            } header: {
                HStack {
                    Text(L("Groups"))
                    Spacer()
                    Button { actions.createGroup() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help(L("New Group\u{2026}"))
                        .accessibilityLabel(L("New Group\u{2026}"))
                }
            }
            Section(L("Tags")) {
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
                        Button(L("Rename Tag\u{2026}")) { onRename(entry.name) }
                        Button(L("New Note with Tag")) { onNewNote(entry.name) }
                        Divider()
                        Button(L("Delete Tag\u{2026}"), role: .destructive) { onDelete(entry.name) }
                    }
                }
                SidebarRow(count: index.untagged) {
                    Label(L("Untagged"), systemImage: "tag.slash")
                }
                .tag(NoteSelection.untagged)
            }
        }
        .listStyle(.sidebar)
    }

    /// Rename, a colour, Delete (which asks, and never deletes a note).
    @ViewBuilder
    private func groupMenu(_ group: NoteGroup) -> some View {
        Button(L("Rename Group\u{2026}")) { actions.renameGroup(group.id) }
        Menu(L("Color")) {
            ForEach(GroupColor.allCases, id: \.self) { color in
                Toggle(isOn: Binding(get: { group.color == color }, set: { _ in actions.setGroupColor(group.id, color) })) {
                    Label { Text(color.displayName) } icon: { Image(nsImage: GroupMenu.swatch(color)) }
                }
            }
        }
        Divider()
        Button(L("Delete Group\u{2026}"), role: .destructive) { actions.deleteGroup(group.id) }
    }

    private func dropNotes(_ providers: [NSItemProvider], then move: @escaping ([UUID]) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let ids = NoteDragPayload.decode(text)
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async { move(ids) }
        }
        return true
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
                .scaledFont(13)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(DailyTemplateText.title)
                    .scaledFont(13, weight: .medium)
                Text(L("Where new daily notes start"))
                    .scaledFont(11)
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
            .scaledFont(11.5, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        // A heading: "Today", "Hoje", "Sexta-feira, 16 de outubro".
        formatter.formattingContext = .beginningOfSentence
        return formatter
    }()
}

/// Shown above the Daily list until "Got it" is pressed, once.
struct DailyIntro: View {
    static var text: String { L("Daily notes. Add the daily tag to any note, as many as you like per day. Notes from your two most recent days stay on the deck. Older ones are archived automatically and kept here. You can set a template for new daily notes.") }

    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Self.text)
                    .scaledFont(12)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer(minLength: 0)
                Button(L("Got it"), action: onDismiss)
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
                .scaledFont(30)
                .foregroundStyle(.tertiary)
            Text(L("No daily notes yet"))
                .scaledFont(13)
                .foregroundStyle(.secondary)
            Text(L("Add the daily tag to a note, or use Today\u{2019}s Daily."))
                .scaledFont(11.5)
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
                .scaledFont(11, monospacedDigit: true)
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
                Button { onTag(tag) } label: {
                    Text("#\(tag)")
                        .scaledFont(size, weight: .medium)
                        .foregroundStyle(color.inkSwiftUI)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(color.spineSwiftUI))
                        .contentShape(Capsule())
                }
                .buttonStyle(InkFocusButtonStyle(color: color, shape: Capsule()))
                    .help(L("Show notes tagged #%@", tag))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Tag %@", tag))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(L("Show notes tagged #%@", tag))
                    .accessibilityAction { onTag(tag) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// One note in the list: a 4 pt bar in the spine colour, the title, one line
/// of preview, the date and the tags.
struct NoteRow: View {
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
                        .scaledFont(13, weight: .semibold)
                        .lineLimit(1)
                    if note.isDaily {
                        Image(systemName: "calendar")
                            .scaledFont(9.5)
                            .foregroundStyle(.secondary)
                            .help(L("Daily note"))
                    }
                    if note.state == .archived {
                        Image(systemName: "archivebox.fill")
                            .scaledFont(9)
                            .foregroundStyle(.secondary)
                            .help(DeckStatus.archivedLine(for: note) ?? L("Archived"))
                            .accessibilityLabel(DeckStatus.archivedLine(for: note) ?? L("Archived"))
                    }
                    // Pinned, kept and about to be archived: a mark and words,
                    // as on the tabs.
                    if note.isPinned {
                        stateMark("pin.fill", L("Pinned to center"))
                    } else if note.keepOnDeck {
                        stateMark("bookmark.fill", L("Kept on deck"))
                    }
                    if note.state != .archived, DeckStatus.isExpiring(note), let line = DeckStatus.line(for: note) {
                        stateMark("clock", line)
                    }
                    if note.hasAttachments {
                        stateMark("paperclip", L("Has attachments"))
                    }
                    Spacer(minLength: 4)
                    Text(Self.age(of: note.editedAt))
                        .scaledFont(10.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(note.preview.isEmpty ? " " : note.preview)
                    .scaledFont(11.5)
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

    private func stateMark(_ symbol: String, _ label: String) -> some View {
        Image(systemName: symbol)
            .scaledFont(9)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }

    /// "Just now" for the first minute (not "in 0 sec" for an edit a few
    /// milliseconds ahead of the clock, nor seconds that count up), then
    /// "5 min ago".
    static func age(of date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return L("Just now") }
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localization.locale
        formatter.unitsStyle = .abbreviated
        // A column of its own, so it starts with a capital like "Just now":
        // "Há 5 min", not "há 5 min" under "Agora mesmo".
        formatter.formattingContext = .beginningOfSentence
        return formatter
    }()
}

/// One note, to edit: its dates and the Open (as a floating note), Archive
/// and Export buttons in the window's own colours, then the note's own
/// editor — spine, title, body, find, colours and tags — exactly as in a
/// note window, saving the same way.
struct NoteReadingPane: View {
    let note: Note
    let store: NoteStore
    let actions: NoteListActions
    var onTag: (String) -> Void

    @StateObject private var model: NoteEditorModel
    @StateObject private var editor = PaneEditorController()

    /// The note was just made: the caret goes to its title.
    var focusTitle = false
    /// Return in the list comes here; Esc here goes back to the list.
    var keyboard: AllNotesKeyboard?
    var onTitleFocused: () -> Void = {}

    init(note: Note, store: NoteStore, actions: NoteListActions, onTag: @escaping (String) -> Void,
         focusTitle: Bool = false, keyboard: AllNotesKeyboard? = nil, onTitleFocused: @escaping () -> Void = {}) {
        self.keyboard = keyboard
        self.note = note
        self.store = store
        self.actions = actions
        self.onTag = onTag
        self.focusTitle = focusTitle
        self.onTitleFocused = onTitleFocused
        _model = StateObject(wrappedValue: NoteEditorModel(note: note, store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoBar
            if model.isLocked {
                paneNotice("lock.fill", Self.lockedReason)
            } else if model.state == .archived {
                paneNotice("archivebox", L("Archived \u{00B7} editing it keeps it in the archive"))
            }
            NoteEditorView(
                model: model,
                presentation: .pane,
                onClose: {},
                onDelete: { actions.delete([note.id]) },
                onTogglePin: {},
                onToggleCenterPin: { actions.setPinned([note.id], !model.isPinned) },
                onShowTools: { editor.showTools() },
                onDailyChip: { onTag(DailyNotes.tag) }
            )
                .background(PaneEditorAnchor(controller: editor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        }
        .padding(16)
        .onAppear {
            wireEditor()
            if focusTitle { placeCaretInTitle(tries: 5) }
        }
        .onReceive(store.changes) { _ in model.refreshFromStore() }
        .onDisappear { model.flush() }
    }

    /// Why a locked note cannot be changed here.
    static var lockedReason: String {
        L("Read-only: this note could not be decrypted with the key on this Mac. Its text is kept as it is, so the right key can still open it.")
    }

    /// A quiet line above the paper: why the note is read-only, or that it
    /// stays archived.
    private func paneNotice(_ symbol: String, _ text: String) -> some View {
        Label {
            // Wraps to the pane's width, never asks for more height than
            // three lines: a fixed height here made the split view measure
            // the text at its narrowest, a word a line, and the whole window
            // grew taller than the screen.
            Text(text)
                .scaledFont(11.5)
                .lineLimit(3)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: symbol)
                .scaledFont(11)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Once SwiftUI has built the editor: its title field takes the caret.
    private func placeCaretInTitle(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if editor.focusTitle() || tries <= 1 {
                onTitleFocused()
            } else {
                placeCaretInTitle(tries: tries - 1)
            }
        }
    }

    private func wireEditor() {
        editor.model = model
        let id = note.id
        let actions = actions
        editor.onSetPinned = { actions.setPinned([id], $0) }
        let store = store
        editor.groupMenu = {
            let note = store.note(id: id)
            return (GroupMenu.choices(store.groups), note?.groupID, note?.isDaily != true)
        }
        editor.onMoveToGroup = { actions.moveToGroup([id], $0) }
        editor.onNewGroup = { actions.newGroupWithNotes([id]) }
        editor.onSetKeepOnDeck = { actions.setKeepOnDeck([id], $0) }
        editor.onDelete = { actions.delete([id]) }
        editor.onOpen = { actions.open(id) }
        if let keyboard {
            keyboard.pane = editor
            editor.onEscape = { [weak keyboard] in keyboard?.focusList() ?? false }
        }
    }

    /// The dates beside the buttons when the pane is wide enough; above them,
    /// on a line of their own, when it is not (or in a longer language).
    private var infoBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                dates
                Spacer(minLength: 8)
                infoButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                dates
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    infoButtons
                }
            }
            // Narrower still (a small window, a longer language): the
            // buttons on one line, the two choices on the next.
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    dates
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) { actionButtons }
                    .lineLimit(1)
                    .fixedSize()
                HStack(spacing: 8) { placeToggles }
                    .lineLimit(1)
                    .fixedSize()
                groupPicker
            }
        }
        .controlSize(.small)
    }

    private var dates: some View {
        Text(L("Created %@ \u{00B7} Edited %@", Self.day.string(from: note.createdAt), Self.day.string(from: note.editedAt)))
            .scaledFont(11)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .fixedSize(horizontal: true, vertical: false)
            .help(L("Created %@\nEdited %@", Self.formatter.string(from: note.createdAt), Self.formatter.string(from: note.editedAt)))
    }

    @ViewBuilder
    private var infoButtons: some View {
        HStack(spacing: 8) {
            Button(L("Open")) { actions.open(note.id) }
            placeToggles
            groupPicker
            if note.state == .archived {
                Button(L("Move to Deck")) { actions.unarchive([note.id]) }
            } else {
                Button(L("Archive")) { actions.archive([note.id]) }
            }
            Button(L("Export\u{2026}")) { actions.export([note.id]) }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(L("Open")) { actions.open(note.id) }
        if note.state == .archived {
            Button(L("Move to Deck")) { actions.unarchive([note.id]) }
        } else {
            Button(L("Archive")) { actions.archive([note.id]) }
        }
        Button(L("Export\u{2026}")) { actions.export([note.id]) }
    }

    @ViewBuilder
    private var placeToggles: some View {
        Toggle(L("Pin to Center"), isOn: Binding(get: { note.isPinned }, set: { actions.setPinned([note.id], $0) }))
            .toggleStyle(.checkbox)
            .disabled(note.state == .archived)
        Toggle(L("Keep on Deck"), isOn: Binding(get: { note.keepOnDeck }, set: { actions.setKeepOnDeck([note.id], $0) }))
            .toggleStyle(.checkbox)
    }

    /// Which group the note is in, and the way to change it: a pop-up in the
    /// pane itself, so putting a note in a group does not depend on knowing the
    /// right click. A daily belongs to Daily.
    private var groupPicker: some View {
        let group = note.groupID.flatMap { store.group(id: $0) }
        let id = note.id
        return Menu {
            Toggle(L("No Group"), isOn: Binding(get: { group == nil }, set: { _ in actions.moveToGroup([id], nil) }))
            if !store.groups.isEmpty { Divider() }
            ForEach(store.groups) { option in
                Toggle(isOn: Binding(get: { group?.id == option.id }, set: { _ in actions.moveToGroup([id], option.id) })) {
                    Label { Text(option.name) } icon: { Image(nsImage: GroupMenu.swatch(option.color)) }
                }
            }
            Divider()
            Button(L("New Group\u{2026}")) { actions.newGroupWithNotes([id]) }
        } label: {
            Label {
                Text(note.isDaily ? L("Daily") : (group?.name ?? L("No Group"))).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "folder")
            }
        }
        .frame(maxWidth: 150)
        .fixedSize()
        .disabled(note.isDaily)
        .help(L("Move to Group"))
        .accessibilityLabel(L("Move to Group"))
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Localization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        // "Created today", not "Created Today": the day sits inside a sentence.
        formatter.formattingContext = .middleOfSentence
        return formatter
    }()
}

private struct MultipleSelectionPane: View {
    let notes: [Note]
    let actions: NoteListActions
    var onClear: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack")
                .scaledFont(34)
                .foregroundStyle(.tertiary)
            Text(L("%d notes selected", notes.count))
                .scaledFont(15, weight: .medium)
            HStack(spacing: 10) {
                Button(L("Export\u{2026}")) { actions.export(notes.map(\.id)) }
                if notes.allSatisfy({ $0.state == .archived }) {
                    Button(L("Move to Stack")) { actions.unarchive(notes.map(\.id)) }
                } else {
                    Button(L("Archive")) { actions.archive(notes.map(\.id)) }
                }
                Button(L("Delete"), role: .destructive) {
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
                .scaledFont(34)
                .foregroundStyle(.tertiary)
            Text(L("Select a note to edit it here"))
                .scaledFont(13)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
