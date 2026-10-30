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
    /// The note All Notes' pane is editing: open, for the time rule, as a
    /// note window is.
    private(set) var paneNoteID: UUID?
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
        NotePreviewController.thumbnail = { [weak store] note in
            guard let store else { return nil }
            return AttachmentText.references(in: note.body).lazy
                .filter(\.isImage).compactMap { store.attachmentImage($0.id) }.first
        }
        rebuildPanels()
        registerHotkeys()
        restoreFloatingNotes()

        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] notes in
                self?.panelsDidChange(activeNotes: notes.filter { $0.state == .active })
            }
            .store(in: &cancellables)

        // The groups, and the colour Daily takes from its template, are on the
        // deck too.
        store.$groups
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.panelsDidChange(activeNotes: self?.store.activeNotes ?? []) }
            .store(in: &cancellables)
        store.$dailyTemplate
            .map(\.color)
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.panelsDidChange(activeNotes: self?.store.activeNotes ?? []) }
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

        // Today's copy of the database: at launch, when the Mac wakes and when
        // the day turns.
        store.backUpIfDue()
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.store.backUpIfDue() }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.store.backUpIfDue() }
            .store(in: &cancellables)
    }

    // MARK: - Daily notes

    /// Today's Daily: the most recently edited daily of today if there is one
    /// (even if it has been archived), otherwise a new one — tagged `daily`,
    /// titled "Daily" and the day and month, starting from the daily template and its colour
    /// — with the cursor in its body.
    func openTodaysDaily() {
        let today = store.today
        if let existing = DailyNotes.todays(store.notes, today: today) {
            open(noteID: existing.id, from: nil)
            return
        }
        do {
            let made = try store.createDaily()
            let offer = carryOverOffer(for: made.note)
            if let offer, settings.carryOverMode == .automatic {
                bring(offer, into: made.note.id)
            }
            open(noteID: made.note.id, from: nil, caret: made.caret)
            if let offer, settings.carryOverMode == .automatic {
                let id = made.note.id
                undoToast.show(message: Self.broughtMessage(offer), duration: settings.undoWindow) { [weak self] in
                    self?.unbring(offer, from: id)
                }
            }
            if let offer, settings.carryOverMode == .ask {
                let id = made.note.id
                noteWindows[id]?.offerCarryOver(offer) { [weak self] in self?.bring(offer, into: id) }
            }
        } catch {
            present(error)
        }
    }

    // MARK: - Unfinished tasks

    /// For Tests/Integration.
    func noteWindowForTesting(_ id: UUID) -> NoteWindowController? { noteWindows[id] }
    var undoToastForTesting: UndoToastController { undoToast }
    var allNotesWindowForTesting: NSWindow? { allNotesWindow?.window }

    /// What the new daily `note` is offered from the last day before it with
    /// a daily, or nothing (Settings > Daily says not to, or there is none).
    private func carryOverOffer(for note: Note) -> DailyCarryOver.Offer? {
        guard settings.carryOverMode != .never, let today = note.dailyDay else { return nil }
        let dailies = store.notes.filter { $0.id != note.id && $0.isDaily && $0.dailyDay != nil }
        let sources = dailies.map { DailyCarryOver.Source(day: $0.dailyDay!, createdAt: $0.createdAt, body: $0.body) }
        return DailyCarryOver.offer(for: today, sources: sources, newBody: note.body,
                                    othersToday: dailies.filter { $0.dailyDay == today }.count)
    }

    /// "3 tasks brought from Thursday".
    static func broughtMessage(_ offer: DailyCarryOver.Offer) -> String {
        let weekday = DailyCarryOver.weekday(of: offer.day)
        return offer.count == 1
            ? L("1 task brought from %@", weekday)
            : L("%d tasks brought from %@", offer.count, weekday)
    }

    /// Undo in Bring automatically: the tasks come out of the daily again, as
    /// long as their block is still as it was brought.
    /// (Through the editors' buffer when one is open, like `bring`.)
    func unbring(_ offer: DailyCarryOver.Offer, from id: UUID) {
        guard let note = store.note(id: id), !note.isLocked else { return }
        let heading = DailyCarryOver.heading(for: offer.day)
        if let buffer = NoteBuffer.existing(for: id, store: store) {
            buffer.editText { DailyCarryOver.removing(offer, from: $0, heading: heading) }
            return
        }
        do {
            try store.setBody(DailyCarryOver.removing(offer, from: note.body, heading: heading), id: id)
        } catch {
            present(error)
        }
    }

    /// Puts the tasks at the end of the daily, under the day they came from.
    /// Every editor showing the note takes the new text too, on top of what
    /// was typed there.
    func bring(_ offer: DailyCarryOver.Offer, into id: UUID) {
        guard let note = store.note(id: id), !note.isLocked else { return }
        Announcer.say(Self.broughtMessage(offer))
        let heading = DailyCarryOver.heading(for: offer.day)
        if let buffer = NoteBuffer.existing(for: id, store: store) {
            buffer.editText { DailyCarryOver.inserting(offer, into: $0, heading: heading) }
            return
        }
        do {
            try store.setBody(DailyCarryOver.inserting(offer, into: note.body, heading: heading), id: id)
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
        let open = Set(noteWindows.keys).union(paneNoteID.map { [$0] } ?? [])
        do {
            for id in open { try store.markOpened(id: id) }
            let archived = try store.archiveDailies(open: open).count
                + store.archiveStale(open: open, days: settings.archiveAfterDays).count
            if archived > 0 {
                Announcer.say(Lplural(archived, L("1 note was archived automatically"), L("%d notes were archived automatically")))
            }
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
        // All Notes' pane edits too.
        NoteEditorModel.flushAll()
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
            controller.update(notes: activeNotes, groups: store.groups, dailyColor: store.dailyTemplate.color)
        }
    }

    private func applyWindowBehavior() {
        panels.values.forEach { $0.applySettings() }
        noteWindows.values.forEach { $0.applyBehavior() }
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        HotkeyService.shared.register([
            .newNote: { [weak self] in self?.newNote(group: self?.openGroupOnDeck()) },
            .allNotes: { [weak self] in self?.showAllNotes() },
            .todaysDaily: { [weak self] in self?.openTodaysDaily() },
            .archive: { [weak self] in self?.showArchive() },
            .focusDeck: { [weak self] in self?.focusDeck() },
        ])
    }

    /// Focus Deck: the deck of the screen the cursor is on takes the keyboard.
    func focusDeck() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let deck = screen.flatMap { panels[$0.displayID] } ?? panels.values.first
        deck?.focusFromKeyboard()
    }

    // MARK: - Commands

    /// The user's group that is open on a deck that is showing, if one is: a
    /// note made now with no deck to say (⌥⌘N, the menu) is born in it.
    func openGroupOnDeck() -> UUID? {
        panels.values.first { $0.isFanned && $0.openUserGroupID != nil }?.openUserGroupID
    }

    /// A new note, at the end of the stack — or of `group`, when it is made
    /// with one open — and open for typing.
    func newNote(tags: [String] = [], group: UUID? = nil) {
        do {
            let note = try store.create(color: settings.defaultNoteColor, tags: tags, group: group)
            open(noteID: note.id, from: nil)
            Announcer.say(L("New note"))
        } catch {
            present(error)
        }
    }

    /// `caret` is where the caret starts in the body, for a note born with
    /// text in it (a daily from the template); otherwise it starts at the end.
    func open(noteID: UUID, from tabFrame: NSRect?, deck: EdgePanelController? = nil, caret: Int? = nil) {
        if let existing = noteWindows[noteID] {
            existing.show()
            return
        }
        guard let note = store.note(id: noteID) else {
            return
        }
        let controller = makeNoteWindow(note: note, originFrame: tabFrame, floating: false)
        if let deck {
            noteOrigins[noteID] = deck.displayID
            deck.noteDidOpen()
        }
        lastNoteOpenedAt = Date()
        controller.initialCaret = caret
        controller.show()
    }

    /// Open from All Notes: the note as a floating note, off the deck, where
    /// it was last left floating — All Notes is a window of its own, and an
    /// anchored note would close as soon as it lost the keyboard to it. A note
    /// already open anchored is lifted off.
    func openFloating(noteID: UUID) {
        if let existing = noteWindows[noteID] {
            if existing.presentation != .detached { existing.togglePresentation() }
            existing.show()
            return
        }
        guard let note = store.note(id: noteID) else { return }
        let controller = makeNoteWindow(note: note, originFrame: nil, floating: true)
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
        controller.onCopyNote = { [weak self] id in
            self?.copyNote(id: id)
        }
        controller.onExportMarkdown = { [weak self] id in
            self?.exportMarkdown(ids: [id])
        }
        controller.onMoveToGroup = { [weak self] id, group in
            self?.moveToGroup([id], group: group)
        }
        controller.onNewGroup = { [weak self] id in
            self?.promptNewGroup(for: [id])
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
            Announcer.say(presentation == .detached ? L("Note floating") : L("Note back on the deck"))
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
        var done = 0
        for id in ids {
            do { try store.archive(id: id); done += 1 } catch { present(error) }
        }
        if done > 0 { Announcer.say(Lplural(done, L("Note archived"), L("%d notes archived"))) }
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
            Announcer.say(PinnedDeck.limitMessage)
        } else if archived {
            undoToast.notice(L("Only notes on the deck can be pinned"))
            Announcer.say(L("Only notes on the deck can be pinned"))
        } else if !ids.isEmpty {
            Announcer.say(on ? L("Pinned to center") : L("Unpinned from center"))
        }
    }

    func unarchive(ids: [UUID]) {
        var done = 0
        for id in ids {
            do { try store.unarchive(id: id); done += 1 } catch { present(error) }
        }
        if done > 0 { Announcer.say(Lplural(done, L("Note back on the deck"), L("%d notes back on the deck"))) }
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

        let message = Lplural(deleted.count, L("Note deleted"), L("%d notes deleted"))
        Announcer.say(message + ". " + L("Undo is in the notice at the bottom of the screen."))
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
                suggestedName: notes.count == 1 ? notes[0].displayTitle : L("KeepNote Export"),
                dailyTemplate: store.dailyTemplate,
                groups: groupsForExport(of: notes),
                attachments: attachmentSource
            )
            reportLockedNotes(skipped)
        } catch {
            present(error)
        }
    }

    /// Export as Markdown…: a folder for each note, with its pictures in it.
    func exportMarkdown(ids: [UUID]) {
        NoteBuffer.flushAll()
        let notes = ids.compactMap { store.note(id: $0) }
        guard !notes.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        do {
            let skipped = try ExportService.runMarkdownFolders(
                notes: notes, groups: groupsForExport(of: notes), attachments: attachmentSource)
            reportLockedNotes(skipped)
        } catch {
            present(error)
        }
    }

    private func reportLockedNotes(_ skipped: Int?) {
        guard let skipped, skipped > 0 else { return }
        let alert = NSAlert()
        alert.messageText = Lplural(skipped, L("1 locked note was not exported"), L("%d locked notes were not exported"))
        alert.informativeText = L("Locked notes could not be decrypted with the key on this Mac, so they are left out of every export format.")
        alert.runModal()
    }

    /// Copy Note: the text with its pictures, on the clipboard as HTML, RTFD
    /// and Markdown at once. A locked note has no text to copy.
    func copyNote(id: UUID) {
        NoteBuffer.flushAll()
        guard let note = store.note(id: id), !note.isLocked else {
            NSSound.beep()
            return
        }
        NoteClipboard.copy(note: note, attachments: attachmentSource)
        Announcer.say(L("Note copied"))
    }

    /// The groups an export carries: those the notes are in — or all of them,
    /// when every note is going, so a group with nothing in it is not lost.
    func groupsForExport(of notes: [Note]) -> [NoteGroup] {
        if notes.count == store.notes.count { return store.groups }
        let used = Set(notes.compactMap(\.groupID))
        return store.groups.filter { used.contains($0.id) }
    }

    /// An attachment's info and bytes, for exports and archives.
    var attachmentSource: AttachmentSource {
        { [store] id in
            guard let info = store.attachments[id], let data = store.attachmentData(id) else { return nil }
            return (info, data)
        }
    }

    func runImport() {
        NSApp.activate(ignoringOtherApps: true)
        do {
            let count = try NoteImporter.run(into: store)
            guard count > 0 else { return }
            let alert = NSAlert()
            alert.messageText = Lplural(count, L("Imported 1 note"), L("Imported %d notes"))
            alert.informativeText = L("Colors, states and dates came across unchanged.")
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
        alert.messageText = Lplural(total, L("Imported 1 note"), L("Imported %d notes"))
        alert.informativeText = L("Colors, states and dates came across unchanged.")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Groups

    /// Moves notes into a group, or out of every group (`nil`): from a tab's
    /// menu, a note's Tools, All Notes, or a drop on a group's tab. Dailies stay
    /// in Daily and are left as they are.
    func moveToGroup(_ ids: [UUID], group: UUID?) {
        do {
            let moved = try store.setGroup(group, for: ids)
            guard moved > 0 else {
                if ids.contains(where: { store.note(id: $0)?.isDaily == true }) {
                    undoToast.notice(L("Daily notes stay in Daily"))
                    Announcer.say(L("Daily notes stay in Daily"))
                }
                return
            }
            // Said without `Lplural`: a group's name is the user's text, and
            // must not be read as a format.
            if let name = group.flatMap({ store.group(id: $0)?.name }) {
                Announcer.say(moved == 1 ? L("Note moved to %@", name) : L("%d notes moved to %@", moved, name))
            } else {
                Announcer.say(Lplural(moved, L("Note moved out of its group"), L("%d notes moved out of their group")))
            }
        } catch {
            present(error)
        }
    }

    /// New Group…: a name, then the notes go into it. Returns the group made.
    @discardableResult
    func promptNewGroup(for ids: [UUID] = []) -> NoteGroup? {
        guard let name = promptGroupName(title: L("New Group"), detail: ids.isEmpty ? L("Name the group.") : L("The notes go into it."),
                                         confirm: L("Create"), current: ""),
              let group = store.createGroup(name: name) else { return nil }
        if !ids.isEmpty { moveToGroup(ids, group: group.id) }
        return group
    }

    /// Rename Group…
    func promptRenameGroup(_ id: UUID) {
        guard let group = store.group(id: id),
              let name = promptGroupName(title: L("Rename \u{201C}%@\u{201D}", group.name), detail: L("Every note in the group stays in it."),
                                         confirm: L("Rename"), current: group.name) else { return }
        store.renameGroup(id: id, to: name)
    }

    /// Delete Group…: says how many notes are left in none; no note is deleted.
    func promptDeleteGroup(_ id: UUID) {
        guard let group = store.group(id: id) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let count = store.notes(inGroup: id).count
        let alert = NSAlert()
        alert.messageText = L("Delete the group \u{201C}%@\u{201D}?", group.name)
        alert.informativeText = count == 0
            ? L("The group is empty.")
            : Lplural(count, L("Its 1 note stays, in no group. No note is deleted."), L("Its %d notes stay, in no group. No note is deleted.", count))
        alert.addButton(withTitle: L("Delete Group"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.deleteGroup(id: id)
            Announcer.say(L("Group deleted"))
        } catch {
            present(error)
        }
    }

    private func promptGroupName(title: String, detail: String, confirm: String, current: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = L("Group name")
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return NoteGroup.cleaned(field.stringValue)
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
        alert.messageText = Lplural(count, L("1 locked note was skipped"), L("%d locked notes were skipped"))
        alert.informativeText = L("Locked notes could not be decrypted with the key on this Mac, so their tags were left as they are.")
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
        alert.messageText = L("Rename \u{201C}#%@\u{201D}", name)
        alert.informativeText = L("Every note with this tag gets the new name.")
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))
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
            confirm.addButton(withTitle: L("Merge"))
            confirm.addButton(withTitle: L("Cancel"))
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
        alert.addButton(withTitle: L("Delete Tag"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteTag(name)
    }

    /// Add Tag…: a name, typed or picked from the existing tags.
    func promptAddTag(to ids: [UUID]) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Add a tag to %@", TagLibrary.notesPhrase(ids.count))
        alert.informativeText = L("Type a new tag or pick an existing one.")
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        box.addItems(withObjectValues: TagLibrary.index(store.notes).tags.map(\.name))
        box.completes = true
        alert.accessoryView = box
        alert.addButton(withTitle: L("Add Tag"))
        alert.addButton(withTitle: L("Cancel"))
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
        alert.messageText = L("Remove a tag from %@", TagLibrary.notesPhrase(ids.count))
        alert.informativeText = L("The notes themselves are kept.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25), pullsDown: false)
        popup.addItems(withTitles: tags.map { "#" + $0 })
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Remove Tag"))
        alert.addButton(withTitle: L("Cancel"))
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
        alert.messageText = L("Export Notes")
        alert.informativeText = L("Choose a format.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 25), pullsDown: false)
        for format in ExportFormat.allCases {
            popup.addItem(withTitle: format.title)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < ExportFormat.allCases.count else { return nil }
        return ExportFormat.allCases[index]
    }

    // MARK: - Auxiliary windows

    /// All Notes' pane shows `id` now, or nothing. Selecting a note is opening
    /// it: its time starts again, and it is not archived while it is there.
    /// The note it showed before was in use until now, as a closing window is.
    func allNotesDidSelect(_ id: UUID?) {
        guard id != paneNoteID else { return }
        if let previous = paneNoteID { try? store.markOpened(id: previous) }
        if heldBuffer?.noteID != id { heldBuffer = nil }
        paneNoteID = id
        if let id { try? store.markOpened(id: id) }
        scheduleArchiveRules()
    }

    private func listActions() -> NoteListActions {
        NoteListActions(
            open: { [weak self] id in
                self?.open(noteID: id, from: nil)
            },
            newNote: { [weak self] in self?.newNote() },
            archive: { [weak self] ids in self?.archive(ids: ids) },
            unarchive: { [weak self] ids in self?.unarchive(ids: ids) },
            delete: { [weak self] ids in self?.delete(ids: ids) },
            export: { [weak self] ids in self?.export(ids: ids) },
            copyNote: { [weak self] id in self?.copyNote(id: id) },
            exportMarkdown: { [weak self] ids in self?.exportMarkdown(ids: ids) },
            openSettings: { [weak self] in self?.showSettings() },
            editDailyTemplate: { [weak self] in self?.showDailyTemplate() },
            setKeepOnDeck: { [weak self] ids, on in self?.setKeepOnDeck(on, ids: ids) },
            setPinned: { [weak self] ids, on in self?.setPinned(on, ids: ids) },
            renameTag: { [weak self] name in self?.promptRenameTag(name) },
            deleteTag: { [weak self] name in self?.promptDeleteTag(name) },
            newNoteWithTag: { [weak self] name in self?.newNote(tags: [name]) },
            addTagToNotes: { [weak self] ids in self?.promptAddTag(to: ids) },
            removeTagFromNotes: { [weak self] ids in self?.promptRemoveTag(from: ids) },
            tagNotes: { [weak self] name, ids in self?.addTag(name, to: ids) },
            select: { [weak self] id in self?.allNotesDidSelect(id) },
            moveToGroup: { [weak self] ids, group in self?.moveToGroup(ids, group: group) },
            newGroupWithNotes: { [weak self] ids in self?.promptNewGroup(for: ids) },
            createGroup: { [weak self] in self?.promptNewGroup() },
            renameGroup: { [weak self] id in self?.promptRenameGroup(id) },
            deleteGroup: { [weak self] id in self?.promptDeleteGroup(id) },
            setGroupColor: { [weak self] id, color in self?.store.setGroupColor(color, id: id) },
            reorderGroups: { [weak self] ids in self?.store.reorderGroups(ids: ids) }
        )
    }

    /// All Notes' actions: Open there opens the note floating, and New Note
    /// makes the note inside the pane.
    private func allNotesActions() -> NoteListActions {
        var actions = listActions()
        actions.open = { [weak self] id in self?.openFloating(noteID: id) }
        actions.newNote = { [weak self] in self?.newNoteInAllNotes() }
        return actions
    }

    /// The buffer of a daily just made in All Notes, holding its "Bring them?"
    /// offer until the pane picks it up.
    private var heldBuffer: NoteBuffer?

    /// New Note in All Notes: the note is made for the list on show — with its
    /// tag on a tag's list, as today's daily on Daily — then selected, with
    /// the caret in its title, in the pane. A list that would not show it
    /// (Archived) gives way to All Notes.
    @discardableResult
    func newNoteInAllNotes() -> UUID? {
        let current = settings.allNotesSelection.flatMap(NoteSelection.init(storageValue:)) ?? .default
        let note: Note
        var list = current
        do {
            switch current {
            case .tag(let name):
                note = try store.create(color: settings.defaultNoteColor, tags: [name])
            case .library(.daily):
                let made = try store.createDaily()
                note = made.note
                startCarryOver(for: made.note) { [weak self] offer in
                    guard let self else { return }
                    let buffer = NoteBuffer.shared(for: made.note, store: self.store)
                    buffer.carryOverOffer = CarryOverBanner(
                        count: offer.count, weekday: DailyCarryOver.weekday(of: offer.day)
                    ) { [weak self] yes in if yes { self?.bring(offer, into: made.note.id) } }
                    self.heldBuffer = buffer
                }
            case .library(.archived):
                note = try store.create(color: settings.defaultNoteColor)
                list = .default
            default:
                note = try store.create(color: settings.defaultNoteColor)
            }
        } catch {
            present(error)
            return nil
        }
        Announcer.say(L("New note"))
        showAllNotes(selecting: list, note: note.id)
        return note.id
    }

    /// What a new daily does with the last day's unfinished tasks: brings
    /// them with a notice to undo (Bring automatically), or hands the offer to
    /// `ask` (Ask each time).
    private func startCarryOver(for note: Note, ask: (DailyCarryOver.Offer) -> Void) {
        guard let offer = carryOverOffer(for: note) else { return }
        switch settings.carryOverMode {
        case .automatic:
            bring(offer, into: note.id)
            let id = note.id
            undoToast.show(message: Self.broughtMessage(offer), duration: settings.undoWindow) { [weak self] in
                self?.unbring(offer, from: id)
            }
        case .ask:
            ask(offer)
        case .never:
            break
        }
    }

    /// All Notes, in front. `selecting` picks what the sidebar shows: kept for
    /// the next opening, and sent to the window if it is already open.
    /// `template` also selects the daily template's row, on the Daily list.
    /// `note` selects that note too, with the caret in its title.
    func showAllNotes(selecting selection: NoteSelection? = nil, template: Bool = false, note: UUID? = nil) {
        if let selection {
            settings.allNotesSelection = selection.storageValue
            var info: [String: Any] = ["selection": selection.storageValue, "template": template]
            if let note { info["note"] = note.uuidString }
            NotificationCenter.default.post(name: .keepNoteShowNotesSelection, object: nil, userInfo: info)
        }
        if let allNotesWindow {
            allNotesWindow.show()
            return
        }
        let controller = HostingWindowController(
            title: L("All Notes"),
            size: NSSize(width: 1080, height: 640),
            autosaveName: "KeepNote.AllNotes",
            minSize: NSSize(width: 900, height: 480),
            rootView: AllNotesView(
                store: store, actions: allNotesActions(),
                initialSelection: template ? [DailyTemplatePane.rowID] : note.map { [$0] } ?? [],
                focusTitleOf: note)
        )
        controller.onClose = { [weak self] in
            self?.allNotesWindow = nil
            self?.allNotesDidSelect(nil)
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
            title: L("[noun] Archive"),
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
                    showWelcome: { [weak self] in self?.showWelcome() },
                    editDailyTemplate: { [weak self] in self?.showDailyTemplate() },
                    relaunch: { [weak self] in
                        self?.flushEverything()
                        AppRelaunch.relaunch()
                    },
                    backUpNow: { [weak self] in self?.backUpNow() },
                    restoreBackup: { [weak self] in self?.promptRestore() }
                ),
                store: store
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

    // MARK: - Backups

    /// Back Up Now: what every editor holds is written, then copied.
    func backUpNow() {
        flushEverything()
        do {
            try store.backUp(kind: .manual)
            Announcer.say(L("Backup made"))
        } catch {
            present(error)
        }
    }

    /// Restore…: the backups with their date and how many notes each holds,
    /// then a confirmation. The notes as they are now are backed up first,
    /// and KeepNote reopens with the chosen backup in place of the database.
    func promptRestore() {
        let backups = Backups.list(in: store.backupDirectory)
        NSApp.activate(ignoringOtherApps: true)
        guard !backups.isEmpty else {
            let none = NSAlert()
            none.messageText = L("No backup yet")
            none.informativeText = L("KeepNote makes one each day by itself, or press Back Up Now.")
            none.runModal()
            return
        }
        let pick = NSAlert()
        pick.messageText = L("Restore a Backup")
        pick.informativeText = L("Choose the copy of your notes to go back to.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 25), pullsDown: false)
        let counts = backups.map { Backups.noteCount(of: $0.url) }
        for (backup, count) in zip(backups, counts) {
            popup.addItem(withTitle: Backups.title(backup, notes: count))
        }
        pick.accessoryView = popup
        pick.addButton(withTitle: L("Continue"))
        pick.addButton(withTitle: L("Cancel"))
        guard pick.runModal() == .alertFirstButtonReturn, backups.indices.contains(popup.indexOfSelectedItem) else { return }
        let chosen = backups[popup.indexOfSelectedItem]
        let count = counts[popup.indexOfSelectedItem] ?? 0

        let confirm = NSAlert()
        confirm.messageText = L("Restore the backup from %@?", Backups.title(chosen, notes: nil))
        var detail = Lplural(count, L("Your notes now are replaced by the 1 note in it."), L("Your notes now are replaced by the %d notes in it."))
        detail += " " + L("A backup of your notes as they are now is made first, so you can come back to them. KeepNote reopens to finish.")
        if settings.syncEnabled {
            detail += " " + L("With sync on, notes changed in the sync folder since this backup come back from it.")
        }
        confirm.informativeText = detail
        confirm.addButton(withTitle: L("Restore and Reopen"))
        confirm.addButton(withTitle: L("Cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        restore(chosen)
    }

    /// Checks the backup, sets it aside, backs up the notes as they are, and
    /// reopens; the swap itself happens at the next launch, before the
    /// database is open (`AppDelegate`). A backup that does not check out
    /// changes nothing.
    func restore(_ backup: Backup, relaunch: Bool = true) {
        flushEverything()
        store.waitUntilSaved()
        do {
            let staged = try Backups.stageForRestore(backup.url, in: store.backupDirectory)
            try store.backUp(kind: .beforeRestore)
            settings.pendingRestorePath = staged.path
        } catch {
            present(error)
            return
        }
        if relaunch { AppRelaunch.relaunch() }
    }

    /// Edit Daily Template…: All Notes on the Daily list, the template's row
    /// selected, whichever way it was asked for.
    func showDailyTemplate() {
        showAllNotes(selecting: .library(.daily), template: true)
    }

    /// First launch only (or `--show-welcome`). "Get Started" records that the
    /// welcome was seen; closing the window by any other route does too.
    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.show()
            return
        }
        let controller = HostingWindowController(
            title: L("Welcome to KeepNote"),
            size: NSSize(width: 440, height: 724),
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
            string: L("Sticky notes on the edge of your screen."),
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
        case .copyNote: copyNote(id: id)
        case .exportMarkdown: exportMarkdown(ids: [id])
        case .moveToGroup(let group): moveToGroup([id], group: group)
        case .newGroup: promptNewGroup(for: [id])
        }
    }

    func edgePanelDidRequestNewNote(_ controller: EdgePanelController) {
        newNote(group: controller.openUserGroupID)
    }

    func edgePanelOpenGroup(_ controller: EdgePanelController) -> UUID? {
        controller.openUserGroupID
    }

    func edgePanel(_ controller: EdgePanelController, didDropNotes ids: [UUID], onGroup id: UUID) {
        moveToGroup(ids, group: id)
    }

    func edgePanel(_ controller: EdgePanelController, didChoose color: GroupColor, forGroup id: UUID) {
        store.setGroupColor(color, id: id)
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

        func add(_ title: String, _ action: Selector, _ key: String = "", global: GlobalCommand? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            if let global { HotkeyService.shared.applyShortcut(for: global, to: item) }
            menu.addItem(item)
        }

        add(L("New Note"), #selector(menuNewNote), global: .newNote)
        add(L("Today\u{2019}s Daily"), #selector(menuTodaysDaily), global: .todaysDaily)
        add(L("Edit Daily Template\u{2026}"), #selector(menuEditDailyTemplate))
        // Opening a window asks nothing more, so no ellipsis, as in File.
        add(L("All Notes"), #selector(menuAllNotes), global: .allNotes)
        add(L("[noun] Archive"), #selector(menuArchive), global: .archive)
        menu.addItem(.separator())
        add(L("Import\u{2026}"), #selector(menuImport))
        add(L("Settings\u{2026}"), #selector(menuSettings), ",")
        menu.addItem(.separator())
        add(L("About KeepNote"), #selector(menuAbout))
        add(L("Quit KeepNote"), #selector(menuQuit))
        return menu
    }

    @objc func menuNewNote() { newNote(group: openGroupOnDeck()) }
    @objc func menuTodaysDaily() { openTodaysDaily() }
    @objc func menuEditDailyTemplate() { showDailyTemplate() }
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
