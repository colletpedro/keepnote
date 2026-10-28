import AppKit
import CryptoKit
import SwiftUI

// Off-screen renderer for the note views. See Scripts/render.sh.

MainActor.assumeIsolated {
    let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    NSApplication.shared.setActivationPolicy(.prohibited)
    // render.sh's third argument: the Text size to draw with.
    if let size = ProcessInfo.processInfo.environment["KEEPNOTE_TEXT_SIZE"].flatMap(TextSize.init(rawValue:)) {
        AppSettings.shared.textSize = size
    }
    defer { AppSettings.shared.textSize = .standard }

    let dbURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepnote-render-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    let store = try! NoteStore(databaseURL: dbURL, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))

    let body = """
    # Weekly plan

    Things to finish before **Friday**, see [the doc](https://example.com).

    - Write the release notes
    - Review the [[Roadmap]] draft
    - [ ] Book the room
    - [x] Send the invite

    1. First step
    2. Second step

    > Keep it small. Ship it #later
    """

    func render(_ name: String, size: CGSize, appearance: NSAppearance.Name = .aqua, _ view: some View) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = outDir.appendingPathComponent("\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote", url.path)
    }

    /// An AppKit view, drawn the same way.
    func renderView(_ name: String, size: CGSize, _ make: () -> NSView) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let view = make()
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = outDir.appendingPathComponent("\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote", url.path)
    }

    // The deck: one tab per colour, side by side on a neutral backdrop.
    do {
        let long = ["Weekly plan", "Groceries and errands for the week", "Ideas", "Trip to Lisbon", "Reading list"]
        let size = CGSize(width: 48 * 5 + 6 * 6, height: 120)
        renderView("deck-tabs", size: size) {
            let backdrop = NSView()
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor
            for (i, color) in NoteColor.allCases.enumerated() {
                let note = try! store.create(color: color, title: long[i], body: "x")
                let card = NoteCardView(note: note, height: 104)
                card.isFloating = i == 1 || i == 3   // two floating notes, marked
                card.frame.origin = NSPoint(x: 6 + CGFloat(i) * 54, y: 8)
                backdrop.addSubview(card)
            }
            return backdrop
        }
    }

    for color in NoteColor.allCases {
        let note = try! store.create(color: color, title: "Weekly plan", body: body, tags: ["work", "ideas"])
        let model = NoteEditorModel(note: note, store: store)
        render("editor-anchored-\(String(describing: color))", size: EdgeMetrics.anchoredSize,
               NoteEditorView(model: model, presentation: .anchored, onClose: {}, onDelete: {}, onTogglePin: {}))
        if color == .mint {
            // A new daily offered yesterday's unfinished tasks.
            let daily = try! store.create(color: .mint, title: "Daily 19/10", body: "## Today\n- [ ] ", tags: ["daily"])
            let dailyModel = NoteEditorModel(note: daily, store: store)
            dailyModel.carryOverOffer = CarryOverBanner(count: 3, weekday: DailyCarryOver.weekday(of: DailyDay(year: 2026, month: 10, day: 15))) { _ in }
            render("editor-carry-over", size: EdgeMetrics.anchoredSize,
                   NoteEditorView(model: dailyModel, presentation: .anchored, onClose: {}, onDelete: {}, onTogglePin: {}))
            render("editor-carry-over-detached", size: EdgeMetrics.detachedSize,
                   NoteEditorView(model: dailyModel, presentation: .detached, onClose: {}, onDelete: {}, onTogglePin: {}))
        }
        if color == .butter {
            render("editor-detached", size: EdgeMetrics.detachedSize,
                   NoteEditorView(model: model, presentation: .detached, onClose: {}, onDelete: {}, onTogglePin: {}))
        }
        if color == .sky {
            render("preview-sky", size: EdgeMetrics.previewSize, NotePreviewView(note: note))
            // No title of its own: the first body line stands in, and the
            // preview must not repeat it.
            let untitled = try! store.create(color: .mint, title: "", body: "Call the dentist\nBring the insurance card and the old x-rays, and ask about the invoice.")
            render("preview-untitled", size: EdgeMetrics.previewSize, NotePreviewView(note: untitled))
        }
    }

    // MARK: Attachments: an image fitted to the note, a file card, a missing one.
    do {
        let image = NSImage(size: NSSize(width: 800, height: 450), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo])!.draw(in: rect, angle: 30)
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: 300, y: 120, width: 200, height: 200)).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let png = rep.representation(using: .png, properties: [:])!
        let picture = try! store.addAttachment(png, name: "Sunset.png")
        let pdf = try! store.addAttachment(Data(repeating: 7, count: 245_000), name: "Invoice October.pdf", type: .pdf)
        let missing = String(repeating: "ab", count: 32)
        let text = """
        Trip photos and the invoice.

        \(AttachmentText.token(id: picture.id, isImage: true, label: "A gradient with a white sun"))
        \(AttachmentText.token(id: pdf.id, isImage: false, label: pdf.name))
        - [ ] Send the invoice
        \(AttachmentText.token(id: missing, isImage: true, label: ""))
        """
        let note = try! store.create(color: .butter, title: "Lisbon", body: text)
        let model = NoteEditorModel(note: note, store: store)
        render("editor-attachments", size: EdgeMetrics.detachedSize,
               NoteEditorView(model: model, presentation: .detached, onClose: {}, onDelete: {}, onTogglePin: {}))
        render("editor-attachments-anchored", size: EdgeMetrics.anchoredSize,
               NoteEditorView(model: model, presentation: .anchored, onClose: {}, onDelete: {}, onTogglePin: {}))
        render("preview-attachment", size: EdgeMetrics.previewSize,
               NotePreviewView(note: store.note(id: note.id)!, thumbnail: store.attachmentImage(picture.id)))
    }

    // MARK: All Notes, in a real titled window so the toolbar draws too.

    /// Draws the whole window frame (title bar and toolbar included), light
    /// or dark. `prepare` runs once the view is on screen, to select things.
    func renderWindow(_ name: String, size: CGSize, appearance: NSAppearance.Name, _ view: some View) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.title = L("All Notes")
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), display: false)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let frame = window.contentView!.superview!
        frame.layoutSubtreeIfNeeded()
        let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let url = outDir.appendingPathComponent("\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote", url.path)
        window.orderOut(nil)
    }

    do {
        let listDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-list-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: listDB) }
        let listStore = try! NoteStore(databaseURL: listDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        let samples: [(NoteColor, String, String, [String], NoteState, Double)] = [
            (.sky, "Trip to Lisbon", "Flights on the 12th. Book the tram tour and the fado night.", ["travel", "ideas"], .active, -600),
            (.butter, "Weekly plan", body, ["work", "ideas"], .active, -3600 * 3),
            (.coral, "Groceries", "- Oat milk\n- Lemons\n- Coffee beans", ["home"], .active, -3600 * 26),
            (.mint, "Reading list", "Piranesi, The Overstory, Klara and the Sun", ["reading"], .archived, -3600 * 24 * 5),
            (.lilac, "Call the dentist", "Ask about the invoice and bring the old x-rays.", [], .active, -3600 * 24 * 9),
            (.butter, "Quarterly review", "Numbers, hiring, the roadmap draft.", ["work"], .archived, -3600 * 24 * 30),
        ]
        var firstID: UUID?
        for (color, title, text, tags, state, age) in samples {
            let date = Date(timeIntervalSinceNow: age)
            let note = Note(title: title, body: text, color: color, state: state, tags: tags,
                            createdAt: date.addingTimeInterval(-86400), updatedAt: date)
            try! listStore.insert(note, origin: .local)
            if firstID == nil { firstID = note.id }
        }
        let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                      delete: { _ in }, export: { _ in })
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderWindow("allnotes-\(suffix)", size: CGSize(width: 1080, height: 640), appearance: appearance,
                         AllNotesView(store: listStore, actions: actions, initialSidebar: .default,
                                      initialSelection: firstID.map { [$0] } ?? []))
            renderWindow("allnotes-fills-\(suffix)", size: CGSize(width: 1080, height: 640), appearance: appearance,
                         AllNotesView(store: listStore, actions: actions, initialSidebar: .default,
                                      initialSelection: firstID.map { [$0] } ?? [], fillsWindow: true))
            // The sidebar's vibrancy does not draw off screen inside the
            // window, so it is drawn on its own as well.
            var sidebarSelection = NoteSelection.tag("ideas")
            render("allnotes-sidebar-\(suffix)", size: CGSize(width: 220, height: 420), appearance: appearance,
                   AllNotesSidebar(index: TagLibrary.index(listStore.notes),
                                   selection: Binding(get: { sidebarSelection }, set: { sidebarSelection = $0 })))
        }
    }

    // MARK: All Notes > Daily: grouped by day, archived dailies among them.

    do {
        let dailyDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-daily-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dailyDB) }
        let dailyStore = try! NoteStore(databaseURL: dailyDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        let samples: [(NoteColor, String, String, NoteState, Int, Double)] = [
            (.butter, "Daily", "Standup at ten. Review the deck geometry PR.", .active, 0, -600),
            (.sky, "Reading notes", "Chapter four, the bit about caches.", .active, 0, -3600 * 2),
            (.mint, "Daily", "Wrote the archive rule. Dinner with Ana.", .active, 1, -3600 * 27),
            (.coral, "Daily", "Sync folder, again. Shipped the fix.", .archived, 3, -3600 * 24 * 3),
            (.lilac, "Daily", "Planning week.", .archived, 9, -3600 * 24 * 9),
        ]
        var firstID: UUID?
        for (color, title, text, state, daysAgo, age) in samples {
            let date = Date(timeIntervalSinceNow: age)
            let day = DailyDay(Date(timeIntervalSinceNow: -Double(daysAgo) * 86400))
            let note = Note(title: title, body: text, color: color, state: state, tags: ["daily"],
                            createdAt: date, updatedAt: date, dailyDay: day)
            try! dailyStore.insert(note, origin: .local)
            if firstID == nil { firstID = note.id }
        }
        let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                      delete: { _ in }, export: { _ in })
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderWindow("allnotes-daily-\(suffix)", size: CGSize(width: 1080, height: 640), appearance: appearance,
                         AllNotesView(store: dailyStore, actions: actions, initialSidebar: .library(.daily),
                                      initialSelection: firstID.map { [$0] } ?? []))
        }
    }

    // MARK: All Notes > Daily with the template selected, beside an ordinary
    // note in the same pane, at the default and the minimum window size.

    do {
        let templateDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-template-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: templateDB) }
        let templateStore = try! NoteStore(databaseURL: templateDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        templateStore.setDailyTemplate("# {weekday}, {date}\n\n## Plan\n- [ ] First thing\n- [ ] \n\n## Notes\nWrite here.")
        var dailyID: UUID?
        for (index, title) in ["Daily", "Daily", "Daily"].enumerated() {
            let date = Date(timeIntervalSinceNow: -3600 * Double(index + 1))
            let note = Note(title: title, body: "Standup at ten.\n- [ ] Review the deck", color: .butter, state: .active, tags: ["daily"],
                            createdAt: date, updatedAt: date, dailyDay: DailyDay(Date(timeIntervalSinceNow: -86400 * Double(index))))
            try! templateStore.insert(note, origin: .local)
            if dailyID == nil { dailyID = note.id }
        }
        let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                      delete: { _ in }, export: { _ in })
        let sizes: [(String, CGSize)] = [("default", CGSize(width: 1080, height: 640)), ("min", CGSize(width: 900, height: 480))]
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (sizeName, size) in sizes {
                renderWindow("allnotes-template-\(suffix)-\(sizeName)", size: size, appearance: appearance,
                             AllNotesView(store: templateStore, actions: actions, initialSidebar: .library(.daily),
                                          initialSelection: [DailyTemplatePane.rowID]))
                renderWindow("allnotes-note-\(suffix)-\(sizeName)", size: size, appearance: appearance,
                             AllNotesView(store: templateStore, actions: actions, initialSidebar: .library(.daily),
                                          initialSelection: dailyID.map { [$0] } ?? []))
            }
        }
        // The template in each of the five colours.
        for color in NoteColor.allCases {
            templateStore.setDailyTemplate(color: color)
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                renderWindow("allnotes-template-color-\(String(describing: color))-\(suffix)", size: CGSize(width: 1080, height: 640), appearance: appearance,
                             AllNotesView(store: templateStore, actions: actions, initialSidebar: .library(.daily),
                                          initialSelection: [DailyTemplatePane.rowID]))
            }
        }
        templateStore.setDailyTemplate(color: .butter)
    }

    // MARK: All Notes > Daily with no daily at all.

    do {
        let emptyDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-nodaily-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: emptyDB) }
        let emptyStore = try! NoteStore(databaseURL: emptyDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        _ = try! emptyStore.create(title: "Plain", body: "x", tags: ["work"])
        let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                      delete: { _ in }, export: { _ in })
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderWindow("allnotes-daily-empty-\(suffix)", size: CGSize(width: 1080, height: 640), appearance: appearance,
                         AllNotesView(store: emptyStore, actions: actions, initialSidebar: .library(.daily)))
        }
    }

    // MARK: Settings > General and the welcome window.

    let paneActions = SettingsActions(chooseSyncFolder: {}, forgetSyncFolder: {}, importNotes: {},
                                      exportAll: {}, showWelcome: {})
    @MainActor func pane(_ tab: SettingsTab) -> CGSize { CGSize(width: SettingsWindowController.paneWidth, height: tab.paneHeight) }
    render("settings-general", size: pane(.general), GeneralSettingsPane(settings: AppSettings.shared, actions: paneActions))
    // A language picked but not yet in effect: the Relaunch Now row.
    let picked = AppSettings(defaults: UserDefaults(suiteName: "keepnote-render-\(UUID().uuidString)")!)
    picked.language = Localization.launchChoice == .english ? .portuguese : .english
    render("settings-general-relaunch", size: pane(.general), GeneralSettingsPane(settings: picked, actions: paneActions))
    render("settings-notes", size: pane(.notes), NotesSettingsPane(settings: AppSettings.shared))
    render("settings-daily", size: pane(.daily), DailySettingsPane(actions: paneActions))
    render("settings-sync", size: pane(.sync),
           SyncSettingsPane(settings: AppSettings.shared, sync: FolderSyncService(store: store), actions: paneActions))
    render("archive", size: CGSize(width: 560, height: 440), ArchiveView(store: store, actions: NoteListActions(
        open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in }, delete: { _ in }, export: { _ in })))
    render("settings-deck", size: CGSize(width: SettingsWindowController.paneWidth, height: SettingsTab.deck.paneHeight),
           DeckSettingsPane(settings: AppSettings.shared))
    render("welcome", size: CGSize(width: 440, height: 724), WelcomeView(onDone: {}))
    render("settings-shortcuts", size: CGSize(width: SettingsWindowController.paneWidth, height: SettingsTab.shortcuts.paneHeight),
           ShortcutsSettingsPane())
    render("settings-about", size: CGSize(width: SettingsWindowController.paneWidth, height: SettingsTab.about.paneHeight),
           AboutSettingsPane(actions: SettingsActions(chooseSyncFolder: {}, forgetSyncFolder: {}, importNotes: {},
                                                      exportAll: {}, showWelcome: {})))

    // MARK: Motion checks (windows and views driven on springs, off screen)

    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    var motionFailures = 0
    func check(_ name: String, _ ok: Bool) {
        print(ok ? "PASS" : "FAIL", name)
        if !ok { motionFailures += 1 }
    }

    // A view springs to its target, overshoots a little, and settles exactly.
    do {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let view = SpringView(frame: NSRect(x: 0, y: 0, width: 48, height: 100))
        host.addSubview(view)
        view.place(frame: view.frame, alpha: 1)
        view.move(to: NSRect(x: 200, y: 50, width: 48, height: 100), config: .deck)
        spin(0.12)
        check("view: in flight after 0.12 s", view.frame.minX > 5 && view.frame.minX < 200)
        let midX = view.frame.minX
        // Interrupted: aimed back at the start while moving. It bends toward the
        // new goal from where it is — no jump to either end. (Velocity carry-over
        // itself is covered by the pure SpringValue tests.)
        view.move(to: NSRect(x: 0, y: 0, width: 48, height: 100), config: .deck)
        spin(0.03)
        check("view: an interruption does not jump", abs(view.frame.minX - midX) < 60)
        spin(1.2)
        check("view: settles exactly on the new target", view.frame == NSRect(x: 0, y: 0, width: 48, height: 100))
    }

    // Delay: the view stays put until its turn.
    do {
        let view = SpringView(frame: NSRect(x: 0, y: 0, width: 48, height: 100))
        view.place(frame: view.frame, alpha: 0)
        view.move(to: NSRect(x: 100, y: 0, width: 48, height: 100), alpha: 1, config: .deck, delay: 0.2)
        spin(0.1)
        check("view: waits out its delay", view.frame.minX == 0 && view.alphaValue == 0)
        spin(1.0)
        check("view: then arrives and is opaque", view.frame.minX == 100 && view.alphaValue == 1)
    }

    // A window follows the same spring, and an interrupted close can reopen.
    do {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 48, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let motion = WindowMotion(window: window)
        motion.place(frame: NSRect(x: 100, y: 100, width: 48, height: 60), alpha: 0)
        let open = NSRect(x: 100, y: 100, width: 380, height: 300)
        motion.move(to: open, alpha: 1, config: .note)
        spin(0.1)
        check("window: growing after 0.1 s", window.frame.width > 48 && window.frame.width < 380)
        var closed = false
        motion.move(to: NSRect(x: 100, y: 100, width: 48, height: 60), alpha: 0, config: .note) { closed = true }
        spin(0.05)
        motion.move(to: open, alpha: 1, config: .note)   // reopened mid-close
        spin(1.2)
        check("window: reopening mid-close lands open", window.frame == open && window.alphaValue == 1)
        check("window: the interrupted close never completed", !closed)
    }

    // Reduce Motion: geometry jumps, opacity fades.
    do {
        Motion.reduceMotionOverride = true
        let view = SpringView(frame: NSRect(x: 0, y: 0, width: 48, height: 100))
        view.place(frame: view.frame, alpha: 0)
        view.move(to: NSRect(x: 300, y: 20, width: 48, height: 100), alpha: 1, config: .deck, delay: 0.3)
        check("reduce motion: the frame jumps at once, no travel", view.frame.minX == 300 && view.frame.minY == 20)
        check("reduce motion: not yet opaque", view.alphaValue < 1)
        spin(0.5)
        check("reduce motion: fades in within half a second", view.alphaValue == 1)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let motion = WindowMotion(window: window)
        motion.place(frame: window.frame, alpha: 0)
        motion.move(to: NSRect(x: 50, y: 50, width: 380, height: 300), alpha: 1, config: .note)
        check("reduce motion: window frame jumps", window.frame == NSRect(x: 50, y: 50, width: 380, height: 300))
        spin(0.5)
        check("reduce motion: window fades in", window.alphaValue == 1)
        Motion.reduceMotionOverride = nil
    }

    // MARK: Status glyph: the three files from Resources/ as one 18 pt template.

    do {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let image = StatusItemController.glyph(in: resources)
        check("glyph: loads", image != nil)
        if let image {
            check("glyph: 18 x 18 pt", image.size == NSSize(width: 18, height: 18))
            check("glyph: template", image.isTemplate)
            let pixels = image.representations.map(\.pixelsWide).sorted()
            check("glyph: three representations, 18/36/54 px (got \(pixels))", pixels == [18, 36, 54])
            check("glyph: every representation is 18 pt", image.representations.allSatisfy { $0.size == NSSize(width: 18, height: 18) })
        }
    }

    // MARK: Tag edits across notes: written one by one, timestamped, sent to sync.

    do {
        let tagDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-tags-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tagDB) }
        let tagStore = try! NoteStore(databaseURL: tagDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        let old = Date(timeIntervalSinceNow: -3600)
        let a = Note(title: "A", tags: ["work", "ideas"], createdAt: old, updatedAt: old)
        let b = Note(title: "B", tags: ["work"], createdAt: old, updatedAt: old)
        let c = Note(title: "C", tags: ["home"], createdAt: old, updatedAt: old)
        let locked = Note(title: "L", tags: ["work"], createdAt: old, updatedAt: old, isLocked: true)
        for note in [a, b, c, locked] { try! tagStore.insert(note, origin: .local) }

        var events: [(StoreChange, ChangeOrigin)] = []
        let watch = tagStore.changes.sink { events.append($0) }
        defer { watch.cancel() }

        let rename = TagLibrary.renamePlan("work", to: "ideas", in: tagStore.notes)
        let written = try! tagStore.applyTagPlan(rename)
        check("rename: two notes written, the locked one counted", written == 2 && rename.skippedLocked == 1)
        check("rename: merged where both were", tagStore.note(id: a.id)?.tags == ["ideas"])
        check("rename: renamed elsewhere", tagStore.note(id: b.id)?.tags == ["ideas"])
        check("rename: untouched note keeps its date", tagStore.note(id: c.id)?.updatedAt == old)
        check("rename: locked note untouched", tagStore.note(id: locked.id)?.tags == ["work"]
              && tagStore.note(id: locked.id)?.updatedAt == old)
        check("rename: updatedAt moves on", (tagStore.note(id: a.id)?.updatedAt ?? old) > old
              && (tagStore.note(id: b.id)?.updatedAt ?? old) > old)
        let updated = events.compactMap { event -> UUID? in
            if case .updated(let id) = event.0, event.1 == .local { return id } else { return nil }
        }
        check("rename: one local change per note, which sync pushes", Set(updated) == [a.id, b.id] && updated.count == 2)

        events.removeAll()
        let delete = TagLibrary.deletePlan("ideas", in: tagStore.notes)
        try! tagStore.applyTagPlan(delete)
        check("delete: tag gone, notes kept", tagStore.notes.count == 4
              && tagStore.note(id: a.id)?.tags == [] && tagStore.note(id: b.id)?.tags == [])
        check("delete: two local changes", events.filter { $0.1 == .local }.count == 2)
        let deleteLocked = TagLibrary.deletePlan("work", in: tagStore.notes)
        check("delete: a locked note with the tag is skipped and counted",
              deleteLocked.changes.isEmpty && deleteLocked.skippedLocked == 1)

        // What is on disk, not just in memory.
        try! tagStore.reload()
        check("reload: edits persisted", tagStore.note(id: b.id)?.tags == [] && tagStore.note(id: c.id)?.tags == ["home"])
    }

    // MARK: Main menu: ⌘W closes the window, ⌘Q quits the whole app.

    do {
        let menuDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-menu-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: menuDB) }
        let menuStore = try! NoteStore(databaseURL: menuDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        let coordinator = AppCoordinator(store: menuStore)
        let menu = MainMenu.make(target: coordinator)
        func item(_ key: String) -> NSMenuItem? {
            menu.items.compactMap(\.submenu).flatMap(\.items)
                .first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == [.command] }
        }
        check("menu: ⌘W is Close, sent to the window", item("w")?.action == #selector(NSWindow.performClose(_:)) && item("w")?.target == nil)
        check("menu: ⌘Q is Quit KeepNote, the coordinator's", item("q")?.action == #selector(AppCoordinator.menuQuit)
              && item("q")?.target === coordinator)
        let delegate = AppDelegate()
        check("closing the last window does not quit", !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    // MARK: Dragging a note off the deck and back (cursor positions given).

    do {
        let dragDB = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepnote-drag-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dragDB) }
        let dragStore = try! NoteStore(databaseURL: dragDB, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
        let note = try! dragStore.create(color: .sky, title: "Drag me", body: "x")
        AppSettings.shared.setDetachedFrame(nil, for: note.id)
        let controller = NoteWindowController(note: note, store: dragStore, originFrame: nil, cascadeIndex: 0)
        controller.showsSnapIndicator = false
        let window = controller.window
        let anchored = window.frame
        let edge = (window.screen ?? NSScreen.main!).visibleFrame
        let grip = NSPoint(x: anchored.minX + 20, y: anchored.maxY - 30)   // on the spine

        controller.drag(.changed, at: grip)
        controller.drag(.changed, at: NSPoint(x: grip.x - 40, y: grip.y))
        check("drag: 40 pt from the edge, still anchored", controller.presentation == .anchored && window.frame == anchored)
        controller.drag(.changed, at: NSPoint(x: grip.x - 41, y: grip.y))
        check("drag: past 40 pt it floats", controller.presentation == .detached)
        check("drag: and takes the floating size", window.frame.size == EdgeMetrics.detachedSize)
        let floated = window.frame
        controller.drag(.changed, at: NSPoint(x: grip.x - 241, y: grip.y - 100))
        check("drag: then follows the cursor", window.frame == floated.offsetBy(dx: -200, dy: -100))
        check("drag: no snap bar away from the edge", !controller.isShowingSnap)
        controller.drag(.ended, at: NSPoint(x: grip.x - 241, y: grip.y - 100))
        check("drag: let go away from the edge, it stays floating", controller.presentation == .detached)
        check("drag: and its place is remembered", AppSettings.shared.detachedFrame(for: note.id) == window.frame)

        // Floating: drag it until its right side is within 24 pt of the edge.
        let start = NSPoint(x: window.frame.midX, y: window.frame.maxY - 20)
        controller.drag(.changed, at: start)
        let toEdge = edge.maxX - window.frame.maxX - 20
        controller.drag(.changed, at: NSPoint(x: start.x + toEdge, y: start.y))
        check("snap: the bar shows within 24 pt of the edge", controller.isShowingSnap)
        controller.drag(.changed, at: NSPoint(x: start.x + toEdge - 10, y: start.y))
        check("snap: 30 pt away the bar goes", !controller.isShowingSnap)
        controller.drag(.changed, at: NSPoint(x: start.x + toEdge, y: start.y))
        controller.drag(.ended, at: NSPoint(x: start.x + toEdge, y: start.y))
        check("snap: let go there, it returns to the deck", controller.presentation == .anchored && !controller.isShowingSnap)
        check("anchored: not resizable", !window.styleMask.contains(.resizable))

        // Floating: resizable, stays when focus goes elsewhere, and comes back
        // at the size and place it was left.
        controller.togglePresentation()
        spin(0.8)
        check("floating: resizable", window.styleMask.contains(.resizable))
        let left = NSRect(x: edge.minX + 60, y: edge.minY + 60, width: 520, height: 380)
        window.setFrame(left, display: false)
        spin(0.5)   // the frame is saved once the user lets go
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        check("floating: clicking elsewhere does not close it", controller.presentation == .detached && !controller.isClosingForChecks)
        controller.togglePresentation()   // back to the deck
        spin(0.8)
        controller.togglePresentation()   // and out again
        spin(0.8)
        check("floating: same size and place as it was left", window.frame == left)
        // Next launch: the note opens floating, in the place it was left.
        let saved = NSRect(x: edge.minX + 80, y: edge.minY + 90, width: 500, height: 400)
        AppSettings.shared.setDetachedFrame(saved, for: note.id)
        let before = AppSettings.shared.floatingNoteIDs
        AppSettings.shared.setFloating(true, noteID: note.id)
        check("floating list: remembers the note", AppSettings.shared.floatingNoteIDs.last == note.id)
        AppSettings.shared.setFloating(true, noteID: note.id)
        check("floating list: once only", AppSettings.shared.floatingNoteIDs.filter { $0 == note.id }.count == 1)
        let reopened = NoteWindowController(note: note, store: dragStore, originFrame: nil, cascadeIndex: 0, floating: true)
        check("relaunch: opens floating", reopened.presentation == .detached && reopened.window.styleMask.contains(.resizable))
        check("relaunch: where it was left", reopened.window.frame == saved)
        AppSettings.shared.setFloating(false, noteID: note.id)
        check("floating list: forgets it", !AppSettings.shared.floatingNoteIDs.contains(note.id))
        AppSettings.shared.floatingNoteIDs = before
        AppSettings.shared.setDetachedFrame(nil, for: note.id)
        controller.close()
    }

    // MARK: The fanned deck at 8, 12, 20, 36 and 60 notes.
    //
    // As on a 14-inch MacBook Pro (1512 × 982 pt, menu bar out): 926 pt for
    // the deck. Eight still fit spaced, twelve to thirty-six overlap, sixty
    // scroll behind a "+N" chip. Drawn with Reduce Motion so every tab is
    // where the deck puts it, on a backdrop wide enough for the lift and the
    // shadows.

    do {
        let deckStore = try! NoteStore(
            databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("keepnote-deck-\(UUID().uuidString).sqlite"),
            cipher: BodyCipher(key: SymmetricKey(size: .bits256))
        )
        let titles = ["Ideas", "Weekly plan", "Groceries and errands", "Call Ana", "Trip to Lisbon",
                      "Reading list", "Q3", "Book the room", "Release notes for 2.0", "Gym"]
        let deckNotes = try! deckStore.create((0..<60).map {
            NoteDraft(title: titles[$0 % titles.count])
        })
        Motion.reduceMotionOverride = true
        let usable: CGFloat = 926
        let width = EdgeMetrics.tabWidth + EdgeMetrics.hoverGutter

        /// `pinned` are positions in the list given to the deck; they are pinned in
        /// that order and the deck is arranged around them, as the app does.
        @MainActor func renderDeck(_ name: String, count: Int, hoverTab: Int? = nil, pinned: [Int] = [], expiring: [Int] = [],
                                   edge: ScreenEdge = .right) {
            var listed = Array(deckNotes.prefix(count))
            for position in expiring {
                listed[position].lastOpenedDay = DailyDay(epoch: DailyDay(Date()).epochDay - 13)
            }
            for (rank, position) in pinned.enumerated() {
                listed[position].pinnedAt = Date(timeIntervalSince1970: 1_790_000_000 + Double(rank))
                listed[position].keepOnDeck = true
            }
            let plan = DeckPlan.make(notes: listed, groups: [], open: nil, usableHeight: usable)
            let content = DeckContent.make(notes: listed, groups: [], dailyColor: .default, plan: plan)
            let notes = plan.entries.compactMap { entry in entry.noteID.flatMap { id in listed.first { $0.id == id } } }
            let geometry = plan.geometry(usableHeight: usable, columnWidth: width, edge: edge)
            let size = CGSize(width: width + 40, height: usable)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor
            window.contentView = backdrop
            // Flush with the backdrop's edge on the deck's side, the room for
            // the lift and the shadows on the other.
            let stack = EdgeStackView(frame: NSRect(x: edge == .right ? 40 : 0, y: (usable - geometry.deckHeight) / 2,
                                                    width: width, height: geometry.deckHeight))
            stack.edge = edge
            backdrop.addSubview(stack)
            stack.fanOut(plan: plan, content: content, usableHeight: usable, stagger: 0, preserveScroll: false)
            stack.setFloating([notes[min(2, count - 1)].id])
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if let hoverTab {
                func collect(_ view: NSView) -> [NoteCardView] {
                    (view as? NoteCardView).map { [$0] } ?? view.subviews.flatMap(collect)
                }
                let cards = collect(stack)
                let card = cards.first { $0.noteID == notes[hoverTab].id }!
                let point = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.maxY - card.visibleSlice / 2), to: nil)
                stack.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: 0, pressure: 0)!)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                check("deck hover: tab \(hoverTab) open", stack.hoveredNoteID == notes[hoverTab].id)
            }
            backdrop.layoutSubtreeIfNeeded()
            let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let url = outDir.appendingPathComponent("\(name).png")
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote", url.path)
        }

        for count in [8, 12, 20, 36, 60] {
            renderDeck("deck-\(count)", count: count)
        }
        renderDeck("deck-20-hover", count: 20, hoverTab: 8)
        renderDeck("deck-pinned-1", count: 6, pinned: [3])
        renderDeck("deck-pinned-3", count: 14, pinned: [4, 9, 1])
        renderDeck("deck-pinned-5", count: 30, pinned: [2, 8, 14, 5, 21])
        renderDeck("deck-pinned-5-many", count: 70, pinned: [2, 8, 14, 5, 21])
        renderDeck("deck-pinned-hover", count: 30, hoverTab: 10, pinned: [2, 8, 14])
        renderDeck("deck-expiring", count: 6, pinned: [3], expiring: [0, 1, 4])
        renderDeck("deck-expiring-packed", count: 24, expiring: [2, 3, 9, 10])
        // The same decks on the left edge, mirrored.
        renderDeck("deck-left-8", count: 8, edge: .left)
        renderDeck("deck-left-36", count: 36, edge: .left)
        renderDeck("deck-left-60", count: 60, edge: .left)
        renderDeck("deck-left-20-hover", count: 20, hoverTab: 8, edge: .left)
        renderDeck("deck-left-pinned-hover", count: 30, hoverTab: 10, pinned: [2, 8, 14], edge: .left)
        renderDeck("deck-left-expiring", count: 6, pinned: [3], expiring: [0, 1, 4], edge: .left)
        // Groups: closed tabs, one open that fits with the others, one open that
        // takes the room and sends the others away. Both edges.
        let groupNames = ["Work", "Home", "Reading and long names for a tab", "Ideas", "Trips"]
        let sampleGroups = groupNames.enumerated().map { NoteGroup(name: $1, color: GroupColor.allCases[$0 * 2 % 12], order: $0) }
        @MainActor func groupedNotes(inGroups sizes: [Int], loose: Int, dailies: Int) -> [Note] {
            var drafts: [NoteDraft] = []
            for (index, size) in sizes.enumerated() {
                for n in 0..<size { drafts.append(NoteDraft(title: "\(groupNames[index].prefix(8)) \(n + 1)", groupID: sampleGroups[index].id)) }
            }
            for n in 0..<dailies { drafts.append(NoteDraft(title: "Daily \(n + 1)", tags: ["daily"])) }
            for n in 0..<loose { drafts.append(NoteDraft(title: titles[n % titles.count])) }
            let store = try! NoteStore(
                databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("keepnote-groups-\(UUID().uuidString).sqlite"),
                cipher: BodyCipher(key: SymmetricKey(size: .bits256)))
            for group in sampleGroups { store.applyIncomingGroup(group, origin: .importer) }
            return try! store.create(drafts)
        }
        @MainActor func renderGroups(_ name: String, notes: [Note], open: DeckGroupRef?, usable: CGFloat = 926, edge: ScreenEdge = .right,
                                     dailyColor: NoteColor = .sky, hoverGroup: Bool = false, groups: [NoteGroup]? = nil) {
            let groups = groups ?? sampleGroups
            let plan = DeckPlan.make(notes: notes, groups: groups, open: open, usableHeight: usable)
            let content = DeckContent.make(notes: notes, groups: groups, dailyColor: dailyColor, plan: plan)
            let geometry = plan.geometry(usableHeight: usable, columnWidth: width, edge: edge)
            let size = CGSize(width: width + 40, height: usable)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor
            window.contentView = backdrop
            let stack = EdgeStackView(frame: NSRect(x: edge == .right ? 40 : 0, y: (usable - geometry.deckHeight) / 2,
                                                    width: width, height: geometry.deckHeight))
            stack.edge = edge
            backdrop.addSubview(stack)
            stack.fanOut(plan: plan, content: content, usableHeight: usable, stagger: 0, preserveScroll: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            if hoverGroup, let index = plan.entries.firstIndex(where: { $0.groupRef != nil }) {
                let frame = stack.geometry.frames[index]
                let point = stack.convert(NSPoint(x: frame.midX, y: frame.maxY - 20 + stack.geometry.columnBottom), to: nil)
                stack.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            }
            backdrop.layoutSubtreeIfNeeded()
            let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let url = outDir.appendingPathComponent("\(name).png")
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote", url.path)
            check("\(name): drawn", rep.pixelsWide > 0)
        }
        let few = groupedNotes(inGroups: [4, 3, 6, 2, 5], loose: 3, dailies: 2)
        let busy = groupedNotes(inGroups: [14, 3, 6, 2, 5], loose: 40, dailies: 2)
        let huge = groupedNotes(inGroups: [60, 3, 6, 2, 5], loose: 20, dailies: 2)
        for edge in ScreenEdge.allCases {
            let tag = edge == .right ? "" : "-left"
            renderGroups("groups-closed\(tag)", notes: few, open: nil, edge: edge)
            renderGroups("groups-closed-hover\(tag)", notes: few, open: nil, edge: edge, hoverGroup: true)
            renderGroups("groups-open-fits\(tag)", notes: few, open: .user(sampleGroups[2].id), edge: edge)
            renderGroups("groups-open-daily\(tag)", notes: few, open: .daily, edge: edge)
            renderGroups("groups-open-expels\(tag)", notes: busy, open: .user(sampleGroups[0].id), edge: edge)
            renderGroups("groups-open-scrolls\(tag)", notes: huge, open: .user(sampleGroups[0].id), edge: edge)
        }
        // A full stack of 11 tabs with a group open: the header and 2 notes among 8 others,
        // or the header and 8 notes among 2 others. The group at the full stage, the
        // strip down its inner side, the colour button on the header.
        for edge in ScreenEdge.allCases {
            let tag = edge == .right ? "" : "-left"
            let two = Array(sampleGroups.prefix(3))
            let twoNotes = groupedNotes(inGroups: [2, 2, 2], loose: 6, dailies: 0)
            renderGroups("groups-full-2\(tag)", notes: twoNotes, open: .user(two[0].id), edge: edge, groups: two)
            let eight = Array(sampleGroups.prefix(2))
            let eightNotes = groupedNotes(inGroups: [8, 2], loose: 1, dailies: 0)
            renderGroups("groups-full-8\(tag)", notes: eightNotes, open: .user(eight[0].id), edge: edge, groups: eight)
        }
        renderGroups("groups-open-small-screen", notes: busy, open: .user(sampleGroups[1].id), usable: 480)
        renderGroups("groups-open-expels-small", notes: busy, open: .user(sampleGroups[0].id), usable: 480)
        var pinnedGroups = few
        pinnedGroups[1].pinnedAt = Date(timeIntervalSince1970: 1_790_000_000)
        pinnedGroups[9].pinnedAt = Date(timeIntervalSince1970: 1_790_000_001)
        renderGroups("groups-pinned-open", notes: pinnedGroups, open: .user(sampleGroups[0].id))
        // What surrounds the groups: the sidebar of All Notes with its Groups
        // section, the "Move to Group" menu (drawn from the menu's own items:
        // a menu does not draw off screen) and the hover magnification slider.
        @MainActor func renderGroupChrome(_ tag: String) {
            var selection = NoteSelection.group(sampleGroups[2].id)
            let counts = GroupLibrary.Counts(
                byGroup: Dictionary(uniqueKeysWithValues: sampleGroups.enumerated().map { ($1.id, [4, 3, 26, 0, 112][$0]) }),
                ungrouped: 3)
            render("groups-sidebar\(tag)", size: CGSize(width: 220, height: 560),
                   AllNotesSidebar(index: TagLibrary.index(few), groups: sampleGroups, groupCounts: counts,
                                   selection: Binding(get: { selection }, set: { selection = $0 })))
            let target = GroupMenu.Target(choose: { _ in }, newGroup: {})
            let item = GroupMenu.makeItem(choices: GroupMenu.choices(sampleGroups), current: sampleGroups[2].id, target: target)
            let menu = item.submenu!
            let font = NSFont.menuFont(ofSize: 0)
            renderView("groups-move-menu\(tag)", size: CGSize(width: max(menu.size.width, 200), height: menu.size.height)) {
                let rows = menu.items.map { entry -> NSView in
                    if entry.isSeparatorItem {
                        let line = NSBox(); line.boxType = .separator
                        line.heightAnchor.constraint(equalToConstant: 9).isActive = true
                        return line
                    }
                    let tick = NSTextField(labelWithString: entry.state == .on ? "\u{2713}" : "")
                    tick.font = font
                    tick.widthAnchor.constraint(equalToConstant: 16).isActive = true
                    let image = NSImageView(image: entry.image ?? NSImage(size: NSSize(width: 11, height: 11)))
                    image.widthAnchor.constraint(equalToConstant: 14).isActive = true
                    let title = NSTextField(labelWithString: entry.title)
                    title.font = font
                    title.lineBreakMode = .byTruncatingTail
                    let row = NSStackView(views: [tick, image, title])
                    row.spacing = 4
                    return row
                }
                let column = NSStackView(views: rows)
                column.orientation = .vertical
                column.alignment = .leading
                column.spacing = 4
                column.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 12)
                column.frame = NSRect(x: 0, y: 0, width: max(menu.size.width, 200), height: menu.size.height)
                return column
            }
            check("groups-move-menu\(tag): wide enough for its longest name", menu.size.width > 0)
            render("groups-settings-deck\(tag)", size: CGSize(width: SettingsWindowController.paneWidth, height: SettingsTab.deck.paneHeight),
                   DeckSettingsPane(settings: AppSettings.shared))
        }
        renderGroupChrome("")
        render("groups-color-popover", size: CGSize(width: 150, height: 110), GroupColorGrid(current: .blue) { _ in }.background(Color(nsColor: .windowBackgroundColor)))
        // With Increase contrast and Reduce transparency on.
        DisplayOptions.increaseContrastOverride = true
        renderGroups("groups-contrast-closed", notes: few, open: nil)
        renderGroups("groups-contrast-open", notes: few, open: .user(sampleGroups[2].id))
        for edge in ScreenEdge.allCases {
            let tag = edge == .right ? "" : "-left"
            renderGroups("groups-contrast-full-2\(tag)", notes: groupedNotes(inGroups: [2, 2, 2], loose: 6, dailies: 0),
                         open: .user(sampleGroups[0].id), edge: edge, groups: Array(sampleGroups.prefix(3)))
            renderGroups("groups-contrast-full-8\(tag)", notes: groupedNotes(inGroups: [8, 2], loose: 1, dailies: 0),
                         open: .user(sampleGroups[0].id), edge: edge, groups: Array(sampleGroups.prefix(2)))
        }
        renderGroupChrome("-contrast")
        render("groups-color-popover-contrast", size: CGSize(width: 150, height: 110), GroupColorGrid(current: .blue) { _ in }.background(Color(nsColor: .windowBackgroundColor)))
        DisplayOptions.increaseContrastOverride = nil
        // With Increase contrast and Reduce transparency on.
        DisplayOptions.increaseContrastOverride = true
        DisplayOptions.reduceTransparencyOverride = true
        renderDeck("deck-contrast", count: 6, hoverTab: 2, pinned: [3], expiring: [0, 4])
        let contrastNote = try! deckStore.create(color: .sky, title: "Weekly plan", body: "- [ ] Send the invoice\n- [x] Book the room\n\nQuiet text here.", tags: ["work"])
        let contrastModel = NoteEditorModel(note: contrastNote, store: deckStore)
        render("editor-contrast", size: EdgeMetrics.detachedSize,
               NoteEditorView(model: contrastModel, presentation: .detached, onClose: {}, onDelete: {}, onTogglePin: {}))
        DisplayOptions.increaseContrastOverride = nil
        DisplayOptions.reduceTransparencyOverride = nil

        // A screen with the deck open on each edge: a peek out of the hovered
        // tab, and a note anchored where it sits, both towards the middle.
        @MainActor func renderScreen(_ name: String, edge: ScreenEdge, anchored: Bool) {
            let area = NSRect(x: 0, y: 0, width: 1000, height: 640)
            let window = NSWindow(contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            let backdrop = NSView(frame: area)
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = NSColor(white: 0.55, alpha: 1).cgColor
            window.contentView = backdrop
            let notes = Array(deckNotes.prefix(6))
            let geometry = DeckGeometry.layout(count: notes.count, usableHeight: area.height - 24, columnWidth: width, edge: edge)
            let deckFrame = NSRect(x: edge.flushX(width: width, in: area), y: area.midY - geometry.deckHeight / 2,
                                   width: width, height: geometry.deckHeight)
            let stack = EdgeStackView(frame: deckFrame)
            stack.edge = edge
            // The tab the peek or the note belongs to, in "screen" coordinates.
            let tab = geometry.frames[2].offsetBy(dx: deckFrame.minX, dy: deckFrame.minY + geometry.columnBottom)
            func card(_ frame: NSRect, _ view: some View, round: CACornerMask) -> NSView {
                let host = NSHostingView(rootView: view)
                host.frame = frame
                host.wantsLayer = true
                host.layer?.cornerRadius = 12
                host.layer?.maskedCorners = round
                host.layer?.masksToBounds = true
                return host
            }
            let inner: CACornerMask = edge == .right ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            if anchored {
                let frame = NoteWindowController.anchoredFrame(in: area, centerY: tab.midY, edge: edge)
                let model = NoteEditorModel(note: notes[2], store: deckStore)
                backdrop.addSubview(card(frame, NoteEditorView(model: model, presentation: .anchored, onClose: {}, onDelete: {}, onTogglePin: {}), round: inner))
            } else {
                let frame = NotePreviewController.frame(for: tab, deckWidth: width, area: area, edge: edge)
                backdrop.addSubview(card(frame, NotePreviewView(note: notes[2]), round: inner))
            }
            // The deck over the card, as the app orders it.
            backdrop.addSubview(stack)
            let plan = DeckPlan.make(notes: notes, groups: [], open: nil, usableHeight: area.height - 24)
            stack.fanOut(plan: plan, content: DeckContent.make(notes: notes, groups: [], dailyColor: .default, plan: plan),
                         usableHeight: area.height - 24, stagger: 0, preserveScroll: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            backdrop.layoutSubtreeIfNeeded()
            let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)!
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let url = outDir.appendingPathComponent("\(name).png")
            try! rep.representation(using: .png, properties: [:])!.write(to: url)
            print("wrote", url.path)
        }
        for edge in ScreenEdge.allCases {
            renderScreen("screen-\(edge.rawValue)-peek", edge: edge, anchored: false)
            renderScreen("screen-\(edge.rawValue)-anchored", edge: edge, anchored: true)
        }
        Motion.reduceMotionOverride = nil
    }

    print(motionFailures == 0 ? "motion: all checks passed" : "motion: \(motionFailures) FAILED")
    exit(motionFailures == 0 ? 0 : 1)
}
