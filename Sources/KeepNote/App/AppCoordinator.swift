import AppKit
import Combine
import SwiftUI

/// Wires the pieces together: one edge panel per screen, a window per open
/// note, the three auxiliary windows, and the global shortcuts.
///
/// Everything the user can do arrives here, from a card, a menu item, a
/// shortcut or a list, and leaves as a call into `NoteStore`.
@MainActor
final class AppCoordinator: NSObject, EdgePanelControllerDelegate {
    let store: NoteStore
    let sync: FolderSyncService
    private let settings = AppSettings.shared

    private var panels: [CGDirectDisplayID: EdgePanelController] = [:]
    private var noteWindows: [UUID: NoteWindowController] = [:]
    /// Which deck a note was opened from, so that deck can stay fanned while
    /// the note is on screen beside it.
    private var noteOrigins: [UUID: CGDirectDisplayID] = [:]
    private var allNotesWindow: HostingWindowController<AllNotesView>?
    private var archiveWindow: HostingWindowController<ArchiveView>?
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: HostingWindowController<WelcomeView>?
    /// The system About panel, while it is open.
    private var aboutPanel: NSWindow?
    private var isAboutOpen = false

        private let undoToast = UndoToastController()
    private lazy var statusItem = StatusItemController { [unowned self] in self.makeAppMenu() }
    /// Opening a note activates the app, which can itself shuffle Spaces.
    /// Without this, a note opened over a full-screen app could close itself
    /// the instant it appeared.
    private var lastNoteOpenedAt = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []
    private var archiveRulesPending = false

    init(store: NoteStore) {
        self.store = store
        self.sync = FolderSyncService(store: store)
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        rebuildPanels()
        registerHotkeys()
        restoreFloatingNotes()

        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] notes in
                self?.panelsDidChange(activeNotes: notes.filter { $0.state == .active })
            }
            .store(in: &cancellables)

        store.changes
            .sink { [weak self] event in
                self?.refreshOpenWindows(for: event.0)
            }
            .store(in: &cancellables)

        store.writeFailures
            .sink { [weak self] error in self?.present(error) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildPanels() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .keepNotePresenceChanged)
            .sink { [weak self] _ in self?.applyPresence() }
            .store(in: &cancellables)
        applyPresence()

        NotificationCenter.default
            .publisher(for: .keepNoteWindowBehaviorChanged)
            .sink { [weak self] _ in self?.applyWindowBehavior() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.flushEverything() }
            .store(in: &cancellables)

        // Switching desktop or full-screen app takes the note with it: an
        // anchored note closes rather than being left open in the Space it was
        // opened over. Pinned notes follow the user instead — see
        // `NoteWindowController.applyBehavior`.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.handleSpaceChange() }
            .store(in: &cancellables)

        // The archive rules (dailies, and notes not opened for a while): at
        // launch, when the Mac wakes, when the day turns, when a note becomes
        // a daily, when a note that was open closes, and when the setting
        // changes.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.scheduleArchiveRules() }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in self?.scheduleArchiveRules() }
            .store(in: &cancellables)
        store.dailyArrived
            .sink { [weak self] in self?.scheduleArchiveRules() }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: .keepNoteArchiveSettingsChanged)
            .sink { [weak self] _ in self?.scheduleArchiveRules() }
            .store(in: &cancellables)
        runArchiveRules()
    }

    // MARK: - Daily notes

    /// Today's Daily: the most recently edited daily of today if there is one
    /// (even if it has been archived), otherwise a new one — tagged `daily`,
    /// titled "Daily" and the day and month — with the cursor in its body.
    func openTodaysDaily() {
        let today = store.today
        if let existing = DailyNotes.todays(store.notes, today: today) {
            open(noteID: existing.id, from: nil)
            return
        }
        do {
            let note = try store.create(
                color: settings.defaultNoteColor,
                title: DailyNotes.title(for: store.now()),
                tags: [DailyNotes.tag]
            )
            open(noteID: note.id, from: nil)
        } catch {
            present(error)
        }
    }

    /// Runs the rule once the current event has finished, however many
    /// triggers came in meanwhile.
    private func scheduleArchiveRules() {
        guard !archiveRulesPending else { return }
        archiveRulesPending = true
        DispatchQueue.main.async { [weak self] in
            self?.archiveRulesPending = false
            self?.runArchiveRules()
        }
    }

    /// Dailies past their two days are archived, and so are notes not opened
    /// for as long as the setting says — unless a window is showing them;
    /// those are caught when the window closes. A note still open today counts
    /// as opened today, so the day turning under it does not start its clock.
    func runArchiveRules() {
        let open = Set(noteWindows.keys)
        do {
            for id in open { try store.markOpened(id: id) }
            try store.archiveDailies(open: open)
            try store.archiveStale(open: open, days: settings.archiveAfterDays)
        } catch {
            present(error)
        }
        // The clocks on the tabs follow the day and the setting, which the
        // store does not announce.
        panelsDidChange(activeNotes: store.activeNotes)
    }

    /// The menu bar icon follows its setting, live.
    func applyPresence() {
        if settings.showInMenuBar { statusItem.show() } else { statusItem.hide() }
        applyDockPolicy()
    }

    // MARK: - Dock

    /// The standard windows open right now. The deck, the peek and the notes
    /// never count.
    private var openWindowKinds: Set<AppWindowKind> {
        var kinds: Set<AppWindowKind> = []
        if allNotesWindow != nil { kinds.insert(.allNotes) }
        if archiveWindow != nil { kinds.insert(.archive) }
        if settingsWindow != nil { kinds.insert(.settings) }
        if welcomeWindow != nil { kinds.insert(.welcome) }
        if isAboutOpen { kinds.insert(.about) }
        return kinds
    }

    /// In the Dock, with the full menu bar, while a standard window is open;
    /// out of it once the last one closes. Called before a standard window is
    /// shown — so it is shown by a `.regular` app — and after one closes.
    func applyDockPolicy() {
        let current: DockPolicy = NSApp.activationPolicy() == .regular ? .regular : .accessory
        guard let wanted = DockPolicy.change(from: current, open: openWindowKinds) else { return }
        switch wanted {
        case .regular: becomeRegular()
        case .accessory: becomeAccessory()
        }
    }

    /// An app that is already active when it turns `.regular` keeps showing
    /// the previous app's menu bar until it is activated again. So when that
    /// is the case, focus goes to the Dock for a moment and comes straight
    /// back, and the window that was in front is made key again.
    private func becomeRegular() {
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(.regular)
        guard wasActive,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        dock.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
            let front = NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey && !($0 is NoteWindow || $0 is EdgePanel || $0 is NotePreviewPanel) }
            front?.makeKeyAndOrderFront(nil)
        }
    }

    /// Turning `.accessory` can leave the app inactive and its windows behind
    /// other apps. A note that had focus gets it back; open notes are put back
    /// in front either way, so nothing seems to vanish with the Dock icon.
    private func becomeAccessory() {
        let key = NSApp.keyWindow
        let noteWindowsOnScreen = noteWindows.values.map(\.window).filter(\.isVisible)
        NSApp.setActivationPolicy(.accessory)
        noteWindowsOnScreen.forEach { $0.orderFrontRegardless() }
        if let key, noteWindowsOnScreen.contains(where: { $0 === key }) {
            NSApp.activate(ignoringOtherApps: true)
            key.makeKeyAndOrderFront(nil)
        }
    }

    /// A standard window closed: it is still on screen while `windowWillClose`
    /// runs, so the policy is decided once it has gone.
    private func standardWindowDidClose() {
        DispatchQueue.main.async { [weak self] in self?.applyDockPolicy() }
    }


    func flushEverything() {
        noteWindows.values.forEach { $0.flush() }
    }

    /// Before the process goes: pending autosaves are written, and the
    /// database and the sync folder are waited on until they have them.
    func finishWriting() {
        flushEverything()
        store.waitUntilSaved()
        sync.waitUntilWritten()
    }

    private func handleSpaceChange() {
        guard Date().timeIntervalSince(lastNoteOpenedAt) > 0.6 else { return }
        for controller in Array(noteWindows.values) where controller.presentation == .anchored {
            controller.close()
        }
        panels.values.forEach { $0.collapse() }
    }

    // MARK: - Panels

    /// One panel per screen, rebuilt whenever the display configuration
    /// changes. Screens that went away take their panel with them.
    private func rebuildPanels() {
        let screens = NSScreen.screens
        let liveIDs = Set(screens.map(\.displayID))

        for (id, controller) in panels where !liveIDs.contains(id) {
            controller.hidePanel()
            panels.removeValue(forKey: id)
        }

        for screen in screens {
            let id = screen.displayID
            if let existing = panels[id] {
                existing.applySettings()
                existing.showPanel()
            } else {
                let controller = EdgePanelController(screen: screen)
                controller.delegate = self
                panels[id] = controller
            }
        }

        updateFloatingMarkers()
        panelsDidChange(activeNotes: store.activeNotes)
    }

    private func panelsDidChange(activeNotes: [Note]) {
        for controller in panels.values {
            controller.update(notes: activeNotes)
        }
    }

    private func applyWindowBehavior() {
        panels.values.forEach { $0.applySettings() }
        noteWindows.values.forEach { $0.applyBehavior() }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        HotkeyService.shared.register([
            .newNote: { [weak self] in self?.newNote() },
            .allNotes: { [weak self] in self?.showAllNotes() },
            .todaysDaily: { [weak self] in self?.openTodaysDaily() },
            .archive: { [weak self] in self?.showArchive() },
        ])
    }

    // MARK: - Commands

    func newNote(tags: [String] = []) {
        do {
            let note = try store.create(color: settings.defaultNoteColor, tags: tags)
            open(noteID: note.id, from: nil)
        } catch {
            present(error)
        }
    }

    func open(noteID: UUID, from tabFrame: NSRect?, deck: EdgePanelController? = nil) {
        if let existing = noteWindows[noteID] {
            existing.show()
            return
        }
        guard let note = store.note(id: noteID) else { return }
        let controller = makeNoteWindow(note: note, originFrame: tabFrame, floating: false)
        if let deck {
            noteOrigins[noteID] = deck.displayID
            deck.noteDidOpen()
        }
        lastNoteOpenedAt = Date()
        controller.show()
    }

    /// The notes that were floating when the app last ran come back floating,
    /// where they were left, without taking focus. Notes deleted since are
    /// dropped from the list.
    private func restoreFloatingNotes() {
        var restored: [UUID] = []
        for id in settings.floatingNoteIDs where noteWindows[id] == nil {
            guard let note = store.note(id: id) else { continue }
            makeNoteWindow(note: note, originFrame: nil, floating: true).showInBackground()
            restored.append(id)
        }
        settings.floatingNoteIDs = restored
    }

    @discardableResult
    private func makeNoteWindow(note: Note, originFrame: NSRect?, floating: Bool) -> NoteWindowController {
        let noteID = note.id
        let controller = NoteWindowController(
            note: note,
            store: store,
            originFrame: originFrame,
            cascadeIndex: noteWindows.count,
            floating: floating
        )
        controller.onClose = { [weak self] id in
            guard let self else { return }
            self.noteWindows.removeValue(forKey: id)
            // It was in use until now, so its time counts from today.
            try? self.store.markOpened(id: id)
            self.updateFloatingMarkers()
            self.scheduleArchiveRules()
            // Closed by the user: it does not come back at the next launch.
            // Quitting closes no window, so floating notes survive a quit.
            self.settings.setFloating(false, noteID: id)
            if let displayID = self.noteOrigins.removeValue(forKey: id) {
                self.panels[displayID]?.noteDidClose()
            }
        }
        controller.onDelete = { [weak self] id in
            self?.delete(ids: [id])
        }
        controller.onSetPinned = { [weak self] id, on in
            self?.setPinned(on, ids: [id])
        }
        controller.onOpenNote = { [weak self] id in
            self?.open(noteID: id, from: nil)
        }
        controller.onShowAllDailies = { [weak self] in
            self?.showAllNotes(selecting: .library(.daily))
        }
        controller.onPresentationChange = { [weak self] id, presentation in
            guard let self else { return }
            self.settings.setFloating(presentation == .detached, noteID: id)
            // Floated off the deck it came from: that deck no longer holds
            // itself open for it.
            if presentation == .detached, let displayID = self.noteOrigins.removeValue(forKey: id) {
                self.panels[displayID]?.noteDidClose()
            }
            self.updateFloatingMarkers()
        }
        noteWindows[noteID] = controller
        // Opened, docked or floating: its time starts again.
        try? store.markOpened(id: noteID)
        if floating { settings.setFloating(true, noteID: noteID) }
        updateFloatingMarkers()
        return controller
    }

    /// Which tabs in the decks belong to floating notes.
    private func updateFloatingMarkers() {
        let ids = Set(noteWindows.values.filter { $0.presentation == .detached }.map(\.noteID))
        panels.values.forEach { $0.setFloating(ids) }
    }

    func archive(ids: [UUID]) {
        for id in ids {
            do { try store.archive(id: id) } catch { present(error) }
        }
    }

    func setKeepOnDeck(_ on: Bool, ids: [UUID]) {
        for id in ids {
            do { try store.setKeepOnDeck(on, id: id) } catch { present(error) }
        }
    }

    /// Pin to Center for these notes; a pin past the limit is refused with a
    /// notice and changes nothing.
    func setPinned(_ on: Bool, ids: [UUID]) {
        var refused = false
        var archived = false
        for id in ids {
            do {
                switch try store.setPinned(on, id: id) {
                case .limitReached: refused = true
                case .notOnDeck: archived = true
                case .done: break
                }
            } catch {
                present(error)
            }
        }
        if refused {
            undoToast.notice(PinnedDeck.limitMessage)
        } else if archived {
            undoToast.notice("Only notes on the deck can be pinned")
        }
    }

    func unarchive(ids: [UUID]) {
        for id in ids {
            do { try store.unarchive(id: id) } catch { present(error) }
        }
    }

    /// Delete is never immediate. The rows leave the UI, a toast counts down,
    /// and only when it runs out does the store purge and write a tombstone.
    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var deleted: [UUID] = []
        for id in ids {
            do {
                try store.delete(id: id)
                deleted.append(id)
                noteWindows[id]?.close()
            } catch {
                present(error)
            }
        }
        guard !deleted.isEmpty else { return }

        let message = deleted.count == 1
            ? "Note deleted"
            : "\(deleted.count) notes deleted"
        undoToast.show(message: message, duration: settings.undoWindow) { [weak self] in
            guard let self else { return }
            for id in deleted {
                try? self.store.undoDelete(id: id)
            }
        }
    }

    func export(ids: [UUID]) {
        let notes = ids.compactMap { store.note(id: $0) }
        guard !notes.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let format = promptForFormat() else { return }
        do {
            let skipped = try ExportService.run(
                notes: notes,
                format: format,
                suggestedName: notes.count == 1 ? notes[0].displayTitle : "KeepNote Export",
                dailyTemplate: store.dailyTemplate
            )
            if let skipped, skipped > 0 {
                let alert = NSAlert()
                alert.messageText = "\(skipped) locked note\(skipped == 1 ? " was" : "s were") not exported"
                alert.informativeText = "Locked notes could not be decrypted with the key on this Mac, so they are left out of every export format."
                alert.runModal()
            }
        } catch {
            present(error)
        }
    }

    func runImport() {
        NSApp.activate(ignoringOtherApps: true)
        do {
            let count = try NoteImporter.run(into: store)
            guard count > 0 else { return }
            let alert = NSAlert()
            alert.messageText = "Imported \(count) note\(count == 1 ? "" : "s")"
            alert.informativeText = "Colors, states and dates came across unchanged."
            alert.runModal()
        } catch {
            present(error)
        }
    }

    /// Import without the panel: used when a file is opened from the Finder.
    /// Opening one `.hmnote` opens that note, brought up to date from the
    /// file when the file is newer.
    func importFiles(at urls: [URL]) {
        var total = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try NoteImporter.importContents(of: url, into: store)
                if urls.count == 1, url.pathExtension == AppPaths.noteFileExtension,
                   let id = result.ids.first, store.note(id: id) != nil {
                    NSApp.activate(ignoringOtherApps: true)
                    open(noteID: id, from: nil)
                    return
                }
                total += result.applied
            } catch {
                present(error)
            }
        }
        guard total > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Imported \(total) note\(total == 1 ? "" : "s")"
        alert.informativeText = "Colors, states and dates came across unchanged."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Tags across notes

    /// Writes a tag edit and says so when locked notes had to be left out.
    func applyTagPlan(_ plan: TagLibrary.Plan) {
        do {
            try store.applyTagPlan(plan)
        } catch {
            present(error)
        }
        guard plan.skippedLocked > 0 else { return }
        let count = plan.skippedLocked
        let alert = NSAlert()
        alert.messageText = "\(count) locked note\(count == 1 ? " was" : "s were") skipped"
        alert.informativeText = "Locked notes could not be decrypted with the key on this Mac, so their tags were left as they are."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func renameTag(_ old: String, to new: String) {
        applyTagPlan(TagLibrary.renamePlan(old, to: new, in: store.notes))
    }

    func deleteTag(_ name: String) {
        applyTagPlan(TagLibrary.deletePlan(name, in: store.notes))
    }

    /// Rename Tag…: the new name, then — if it is another existing tag — a
    /// warning that the two will merge. Returns the name the tag ended up with.
    func promptRenameTag(_ name: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}#\(name)\u{201D}"
        alert.informativeText = "Every note with this tag gets the new name."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        if let block = DailyNotes.renameBlock(name, to: field.stringValue) {
            let blocked = NSAlert()
            blocked.messageText = block.title
            blocked.informativeText = block.detail
            blocked.runModal()
            return nil
        }
        guard let rename = TagLibrary.rename(name, to: field.stringValue, in: store.notes) else { return nil }
        if rename.merges {
            let count = TagLibrary.index(store.notes).entry(named: name)?.count ?? 0
            let message = TagLibrary.mergeMessage(name, into: rename.target, count: count)
            let confirm = NSAlert()
            confirm.messageText = message.title
            confirm.informativeText = message.detail
            confirm.addButton(withTitle: "Merge")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return nil }
        }
        renameTag(name, to: rename.target)
        return rename.target
    }

    /// Delete Tag…: says how many notes lose it; no note is deleted.
    func promptDeleteTag(_ name: String) {
        guard !DailyNotes.isReserved(name) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let count = TagLibrary.index(store.notes).entry(named: name)?.count ?? 0
        let message = TagLibrary.deleteMessage(name, count: count)
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.detail
        alert.addButton(withTitle: "Delete Tag")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteTag(name)
    }

    /// Add Tag…: a name, typed or picked from the existing tags.
    func promptAddTag(to ids: [UUID]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add a tag to \(TagLibrary.notesPhrase(ids.count))"
        alert.informativeText = "Type a new tag or pick an existing one."
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        box.addItems(withObjectValues: TagLibrary.index(store.notes).tags.map(\.name))
        box.completes = true
        alert.accessoryView = box
        alert.addButton(withTitle: "Add Tag")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = box
        guard alert.runModal() == .alertFirstButtonReturn,
              let typed = TagText.normalize([box.stringValue]).first else { return }
        // An existing tag keeps its spelling, accents included.
        addTag(TagLibrary.index(store.notes).entry(named: typed)?.name ?? typed, to: ids)
    }

    /// Remove Tag…: one of the tags these notes carry.
    func promptRemoveTag(from ids: [UUID]) {
        let wanted = Set(ids)
        let tags = TagLibrary.index(store.notes.filter { wanted.contains($0.id) }).used.map(\.name)
        guard !tags.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove a tag from \(TagLibrary.notesPhrase(ids.count))"
        alert.informativeText = "The notes themselves are kept."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25), pullsDown: false)
        popup.addItems(withTitles: tags.map { "#" + $0 })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Remove Tag")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, tags.indices.contains(popup.indexOfSelectedItem) else { return }
        removeTag(tags[popup.indexOfSelectedItem], from: ids)
    }

    func addTag(_ name: String, to ids: [UUID]) {
        let wanted = Set(ids)
        applyTagPlan(TagLibrary.addPlan(name, to: store.notes.filter { wanted.contains($0.id) }))
    }

    func removeTag(_ name: String, from ids: [UUID]) {
        let wanted = Set(ids)
        applyTagPlan(TagLibrary.removePlan(name, from: store.notes.filter { wanted.contains($0.id) }))
    }

    private func promptForFormat() -> ExportFormat? {
        let alert = NSAlert()
        alert.messageText = "Export Notes"
        alert.informativeText = "Choose a format."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 25), pullsDown: false)
        for format in ExportFormat.allCases {
            popup.addItem(withTitle: format.title)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < ExportFormat.allCases.count else { return nil }
        return ExportFormat.allCases[index]
    }

    // MARK: - Auxiliary windows

    private func listActions() -> NoteListActions {
        NoteListActions(
            open: { [weak self] id in self?.open(noteID: id, from: nil) },
            newNote: { [weak self] in self?.newNote() },
            archive: { [weak self] ids in self?.archive(ids: ids) },
            unarchive: { [weak self] ids in self?.unarchive(ids: ids) },
            delete: { [weak self] ids in self?.delete(ids: ids) },
            export: { [weak self] ids in self?.export(ids: ids) },
            openSettings: { [weak self] in self?.showSettings() },
            setKeepOnDeck: { [weak self] ids, on in self?.setKeepOnDeck(on, ids: ids) },
            setPinned: { [weak self] ids, on in self?.setPinned(on, ids: ids) },
            renameTag: { [weak self] name in self?.promptRenameTag(name) },
            deleteTag: { [weak self] name in self?.promptDeleteTag(name) },
            newNoteWithTag: { [weak self] name in self?.newNote(tags: [name]) },
            addTagToNotes: { [weak self] ids in self?.promptAddTag(to: ids) },
            removeTagFromNotes: { [weak self] ids in self?.promptRemoveTag(from: ids) },
            tagNotes: { [weak self] name, ids in self?.addTag(name, to: ids) }
        )
    }

    /// All Notes, in front. `selecting` picks what the sidebar shows: kept for
    /// the next opening, and sent to the window if it is already open.
    func showAllNotes(selecting selection: NoteSelection? = nil) {
        if let selection {
            settings.allNotesSelection = selection.storageValue
            NotificationCenter.default.post(
                name: .keepNoteShowNotesSelection, object: nil, userInfo: ["selection": selection.storageValue])
        }
        if let allNotesWindow {
            allNotesWindow.show()
            return
        }
        let controller = HostingWindowController(
            title: "All Notes",
            size: NSSize(width: 1080, height: 640),
            autosaveName: "KeepNote.AllNotes",
            minSize: NSSize(width: 900, height: 480),
            rootView: AllNotesView(store: store, actions: listActions())
        )
        controller.onClose = { [weak self] in
            self?.allNotesWindow = nil
            self?.standardWindowDidClose()
        }
        allNotesWindow = controller
        applyDockPolicy()
        controller.show()
    }

    func showArchive() {
        if let archiveWindow {
            archiveWindow.show()
            return
        }
        let controller = HostingWindowController(
            title: "Archive",
            size: NSSize(width: 560, height: 440),
            autosaveName: "KeepNote.Archive",
            rootView: ArchiveView(store: store, actions: listActions())
        )
        controller.onClose = { [weak self] in
            self?.archiveWindow = nil
            self?.standardWindowDidClose()
        }
        archiveWindow = controller
        applyDockPolicy()
        controller.show()
    }

    func showSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil {
            let controller = SettingsWindowController(
                settings: settings,
                sync: sync,
                actions: SettingsActions(
                    chooseSyncFolder: { [weak self] in self?.sync.chooseFolder() },
                    forgetSyncFolder: { [weak self] in self?.sync.forgetFolder() },
                    importNotes: { [weak self] in self?.runImport() },
                    exportAll: { [weak self] in self?.menuExportAll() },
                    showWelcome: { [weak self] in self?.showWelcome() }
                )
            )
            controller.onClose = { [weak self] in
                self?.settingsWindow = nil
                self?.standardWindowDidClose()
            }
            settingsWindow = controller
            applyDockPolicy()
        }
        if let tab { settingsWindow?.select(tab) }
        settingsWindow?.show()
    }

    /// First launch only (or `--show-welcome`). "Get Started" records that the
    /// welcome was seen; closing the window by any other route does too.
    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.show()
            return
        }
        let controller = HostingWindowController(
            title: "Welcome to KeepNote",
            size: NSSize(width: 440, height: 690),
            autosaveName: "KeepNote.Welcome",
            styleMask: [.titled, .closable],
            minSize: NSSize(width: 440, height: 300),
            rootView: WelcomeView(onDone: { [weak self] in
                self?.settings.hasLaunchedBefore = true
                self?.welcomeWindow?.close()
            })
        )
        controller.window.center()
        controller.onClose = { [weak self] in
            self?.settings.hasLaunchedBefore = true
            self?.welcomeWindow = nil
            self?.standardWindowDidClose()
        }
        welcomeWindow = controller
        applyDockPolicy()
        controller.show()
    }

    func showAbout() {
        isAboutOpen = true
        applyDockPolicy()
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.activate(ignoringOtherApps: true)
        // The system panel: icon, name, "Version <short> (<build>)" and the
        // copyright all come from Info.plist; only the credits line is ours.
        let credits = NSAttributedString(
            string: "Sticky notes on the edge of your screen.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }(),
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        trackAboutPanel(newSince: before)
    }

    /// The About panel is AppKit's own window: found as the one that was not
    /// there before (or the one already known), and watched until it closes.
    private func trackAboutPanel(newSince before: Set<ObjectIdentifier>) {
        if aboutPanel == nil {
            aboutPanel = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            guard let panel = aboutPanel else {
                // Not found: nothing to watch, so it must not hold the Dock icon.
                isAboutOpen = false
                standardWindowDidClose()
                return
            }
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isAboutOpen = false
                    self?.standardWindowDidClose()
                }
            }
        }
    }

    private func refreshOpenWindows(for change: StoreChange) {
        switch change {
        case .updated(let id), .stateChanged(let id), .restored(let id), .inserted(let id):
            noteWindows[id]?.refresh()
        case .purged(let id), .softDeleted(let id):
            noteWindows[id]?.close()
            if case .purged = change { settings.setDetachedFrame(nil, for: id) }
        case .batch(let ids):
            ids.forEach { noteWindows[$0]?.refresh() }
        case .reloaded:
            noteWindows.values.forEach { $0.refresh() }
        }
    }

    private func present(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentError(error)
    }

    // MARK: - EdgePanelControllerDelegate

    func edgePanel(_ controller: EdgePanelController, didActivateNote id: UUID, from tabFrame: NSRect?) {
        open(noteID: id, from: tabFrame, deck: controller)
    }

    func edgePanel(_ controller: EdgePanelController, didRequest action: NoteCardView.ContextAction, on id: UUID) {
        switch action {
        case .open: open(noteID: id, from: nil)
        case .markComplete: archive(ids: [id])
        case .cycleColor: try? store.cycleColor(id: id)
        case .togglePin:
            if let note = store.note(id: id) { setPinned(!note.isPinned, ids: [id]) }
        case .toggleKeep:
            if let note = store.note(id: id) { setKeepOnDeck(!note.keepOnDeck, ids: [id]) }
        case .delete: delete(ids: [id])
        }
    }

    func edgePanelDidRequestNewNote(_ controller: EdgePanelController) {
        newNote()
    }

    func edgePanelDidRequestTodaysDaily(_ controller: EdgePanelController) {
        openTodaysDaily()
    }

    func edgePanelDidRequestAllNotes(_ controller: EdgePanelController) {
        showAllNotes()
    }

    func edgePanelMenu(_ controller: EdgePanelController) -> NSMenu? {
        makeAppMenu()
    }

    // MARK: - The pill's menu

    /// The app has no Dock icon and no menu bar, so this is where New Note,
    /// Settings and Quit live: right-click on the pill.
    func makeAppMenu() -> NSMenu {
        let menu = NSMenu()

        func add(_ title: String, _ action: Selector, _ key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }

        add("New Note", #selector(menuNewNote))
        add("Today\u{2019}s Daily", #selector(menuTodaysDaily))
        add("All Notes\u{2026}", #selector(menuAllNotes))
        add("Archive\u{2026}", #selector(menuArchive))
        menu.addItem(.separator())
        add("Import\u{2026}", #selector(menuImport))
        add("Settings\u{2026}", #selector(menuSettings), ",")
        menu.addItem(.separator())
        add("About KeepNote", #selector(menuAbout))
        add("Quit KeepNote", #selector(menuQuit))
        return menu
    }

    @objc func menuNewNote() { newNote() }
    @objc func menuTodaysDaily() { openTodaysDaily() }
    @objc func menuAllNotes() { showAllNotes() }
    @objc func menuArchive() { showArchive() }
    @objc func menuImport() { runImport() }
    @objc func menuSettings() { showSettings() }
    @objc func menuAbout() { showAbout() }
    @objc func menuShortcuts() { showSettings(tab: .shortcuts) }
    @objc func menuExportAll() { export(ids: store.notes.map(\.id)) }
    @objc func menuQuit() {
        flushEverything()
        NSApp.terminate(nil)
    }
}
