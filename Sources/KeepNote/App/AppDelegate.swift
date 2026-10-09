import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var appKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy of the app (the ./build one, say, found by Spotlight)
        // would start a second instance with its own deck. Hand the request
        // to the one already running, as a reopen, and leave.
        if handOffToRunningInstance() { return }

        // No Dock icon to start with; `LSUIElement` in Info.plist says the
        // same. The coordinator adds it while a standard window is open.
        NSApp.setActivationPolicy(.accessory)

        logLaunchKind()

        // A cold launch opens no window (the first launch's welcome aside):
        // a launch by the user and one by "Launch at login" cannot yet be told
        // apart with confidence, and the login one must leave only the deck.
        // Opening the app again once it runs does show All Notes (the reopen
        // below). `logLaunchKind` records what each launch said, to settle it.

        // `--show-welcome` opens the welcome window even on a later launch.
        let isFirstLaunch = !AppSettings.shared.hasLaunchedBefore
            || CommandLine.arguments.contains("--show-welcome")

        do {
            let cipher = try BodyCipher.makeDefault()
            let store = try NoteStore(cipher: cipher)
            let coordinator = AppCoordinator(store: store)
            self.coordinator = coordinator
            coordinator.start()
            installAppShortcuts()
            installMainMenu(coordinator: coordinator)
            if isFirstLaunch { coordinator.showWelcome() }
            seedFirstRunNoteIfNeeded(store: store)
        } catch {
            presentFatal(error)
        }
    }

    /// Opening a `.hmnotearchive` or a `.hmnote` from the Finder imports it.
    /// Launch Services hands the sandbox access to exactly those files, so no
    /// extra entitlement is involved.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let coordinator else { return }
        coordinator.importFiles(at: urls)
    }

    /// Opening the app while it is already running (Finder, Launchpad,
    /// Spotlight, the Dock icon) sends this. The answer is always All Notes,
    /// in front — whatever deck or note panels happen to be on screen, so
    /// `hasVisibleWindows` is not consulted.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showAllNotes()
        return false
    }

    /// Writes to the unified log whether the launch event carried the
    /// "launched as login item" flag. Nothing acts on it yet; after a login,
    /// `log show --last 10m --predicate 'subsystem == "com.keepnote.KeepNote"'`
    /// tells whether `SMAppService` launches can be recognised by it.
    private func logLaunchKind() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let eventID = event.map { String(format: "%08x", $0.eventID) } ?? "none"
        let flag = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Logger(subsystem: "com.keepnote.KeepNote", category: "launch")
            .notice("launch event=\(eventID, privacy: .public) loginItemFlag=\(flag, privacy: .public)")
    }

    /// Another KeepNote that started before this one, at any path: ask Launch
    /// Services to open *its* bundle, which reaches it as a reopen (All Notes
    /// in front), and quit. Only an earlier instance counts, so two copies
    /// started together never both step aside.
    private func handOffToRunningInstance() -> Bool {
        let current = NSRunningApplication.current
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let mine = current.launchDate ?? Date()
        let earlier = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
            .filter { other in
                guard let theirs = other.launchDate else { return other.processIdentifier < current.processIdentifier }
                return theirs < mine || (theirs == mine && other.processIdentifier < current.processIdentifier)
            }
        guard let running = earlier.first, let url = running.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // The completion runs off the main thread; it only hops back to quit.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { @Sendable _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Anything still sitting in a 250 ms autosave timer is written now,
        // and the process waits until it is on disk.
        coordinator?.finishWriting()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The deck is the app. ⌘W and the red button close one window — the
        // last standard one takes the Dock icon with it — but only ⌘Q, Quit
        // in a menu or Quit in the Dock end the app, deck included.
        false
    }

    /// Out of the Dock the app has no menu bar, so the handful of app-wide keys
    /// are handled here, whatever the activation policy. A *local* monitor only ever sees events already delivered
    /// to this app — no permission involved.
    private func installAppShortcuts() {
        appKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let coordinator = self.coordinator else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q":
                coordinator.flushEverything()
                NSApp.terminate(nil)
                return nil
            case ",":
                coordinator.showSettings()
                return nil
            default:
                return event
            }
        }
    }

    /// ⌘C/⌘V/⌘X/⌘A/⌘Z are not handled by `NSTextView` itself: AppKit routes them
    /// through the main menu's key equivalents, which then send `copy:`, `paste:`
    /// and friends down the responder chain. So the main menu exists even when
    /// the app is an accessory and never draws it.
    private func installMainMenu(coordinator: AppCoordinator) {
        NSApp.mainMenu = MainMenu.make(target: coordinator)
    }

    /// A first launch with an empty stack would show a pill with nothing in it
    /// and no hint about what to do, so the app writes one note explaining
    /// itself. Only ever once.
    private func seedFirstRunNoteIfNeeded(store: NoteStore) {
        let settings = AppSettings.shared
        // Its own flag: `hasLaunchedBefore` now means "the welcome was seen".
        guard !settings.hasSeededFirstNote, !settings.hasLaunchedBefore else { return }
        settings.hasSeededFirstNote = true
        guard store.notes.isEmpty else { return }

        let newNote = HotkeyService.shared.combo(for: .newNote).displayString
        let allNotes = HotkeyService.shared.combo(for: .allNotes).displayString
        let archive = HotkeyService.shared.combo(for: .archive).displayString
        let daily = HotkeyService.shared.combo(for: .todaysDaily).displayString

        _ = try? store.create(
            color: .mint,
            title: "Welcome to KeepNote",
            body: """
            Your notes live on the right edge of the screen.

            • Move the cursor to the pill and the stack fans out.
            • Click a card to open it. Typing saves on its own.
            • Right-click the pill for the menu.

            Shortcuts
            \(newNote)  new note
            \(allNotes)  all notes
            \(archive)  archive
            \(daily)  today's daily

            Notes are markdown: # titles, **bold**, - lists, - [ ] tasks,
            > quotes. The syntax hides itself except on the line you edit.

            Inside a note: esc closes, ⌘F finds, ⌥⌘C changes color,
            ⇧⌘⌫ deletes with ten seconds to undo.
            """,
            tags: ["welcome"]
        )
    }

    private func presentFatal(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "KeepNote could not start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
