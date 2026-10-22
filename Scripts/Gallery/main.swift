import AppKit
import CryptoKit
import SwiftUI

// The finishing gallery: every screen in the states Scripts/RenderHarness does
// not draw — rich notes (a long title, nested lists, checklists, a table,
// code, a quote, an image, a file), both edges, Increase contrast, the find
// bar, All Notes editing (and the pane filling the window), locked and
// archived notes, the daily template, Settings as whole windows in light and
// dark, the welcome window and the notices. See Scripts/gallery.sh.

MainActor.assumeIsolated {
    let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    NSApplication.shared.setActivationPolicy(.prohibited)
    if let size = ProcessInfo.processInfo.environment["KEEPNOTE_TEXT_SIZE"].flatMap(TextSize.init(rawValue:)) {
        AppSettings.shared.textSize = size
    }
    let savedEdge = AppSettings.shared.screenEdge
    defer {
        AppSettings.shared.textSize = .standard
        AppSettings.shared.screenEdge = savedEdge
        DisplayOptions.increaseContrastOverride = nil
    }

    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("keepnote-gallery-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }
    let store = try! NoteStore(databaseURL: dbURL, cipher: BodyCipher(key: SymmetricKey(size: .bits256)))

    // MARK: Drawing

    /// The view at 2x in a borderless window, or a titled one with its
    /// toolbar when `titled`.
    @MainActor func shoot(_ name: String, size: CGSize, appearance: NSAppearance.Name = .aqua, titled: Bool = false,
               title: String = "", settle: Double = 0.6, prepare: ((NSWindow) -> Void)? = nil, _ view: some View) {
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.title = title
        window.contentView = NSHostingView(rootView: view.environment(\.locale, Localization.locale))
        window.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size), display: false)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        prepare?(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        save(name, titled ? window.contentView!.superview! : window.contentView!)
        window.orderOut(nil)
    }

    @MainActor func shootWindow(_ name: String, _ window: NSWindow, settle: Double = 0.8) {
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        save(name, window.contentView!.superview!)
        window.orderOut(nil)
    }

    @MainActor func save(_ name: String, _ view: NSView) {
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = outDir.appendingPathComponent("\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote", url.lastPathComponent)
    }

    // MARK: Content

    @MainActor func png(_ width: Int, _ height: Int, _ colors: [NSColor]) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSGradient(colors: colors)!.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.75).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - rect.height / 5, y: rect.midY - rect.height / 5,
                                        width: rect.height / 2.5, height: rect.height / 2.5)).fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
    let wide = try! store.addAttachment(png(1600, 900, [.systemTeal, .systemIndigo]), name: "Harbour.png")
    let tall = try! store.addAttachment(png(600, 1400, [.systemOrange, .systemPink]), name: "Tower.png")
    let small = try! store.addAttachment(png(120, 80, [.systemGreen, .systemMint]), name: "Stamp.png")
    let pdf = try! store.addAttachment(Data((0..<1_340_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }), name: "Invoice October 2026 – final version for the accountant.pdf", type: .pdf)
    let zip = try! store.addAttachment(Data(repeating: 4, count: 12_000), name: "Photos.zip", type: .zip)

    let rich = """
    Things to settle before **Friday**, see [the brief](https://example.com/brief) and `notes.md`.

    - Write the release notes
        - The part about backups
            - With the folder's path
    - Review the [[Roadmap]] draft
    - [ ] Book the room for the long planning session with the whole team, the one that always overruns
    - [x] Send the invite
        - [ ] Attach the agenda

    1. First step
    2. Second step
    10. Tenth step

    > Keep it small. Ship it.
    > The second line of the quote.

    | Task | Owner | Due |
    | --- | --- | --- |
    | Release notes | Ana | Thu |
    | Room | Pedro | Fri |

    ```
    let answer = 42
    print(answer)
    ```

    ---
    \(AttachmentText.token(id: wide.id, isImage: true, label: "The harbour at dusk"))
    \(AttachmentText.token(id: pdf.id, isImage: false, label: pdf.name))
    \(AttachmentText.token(id: zip.id, isImage: false, label: zip.name))
    \(AttachmentText.token(id: small.id, isImage: true, label: ""))
    Last line after the attachments.
    """
    let longTitle = "Planning the October offsite in Lisbon with everyone, the venue and the budget"
    let richNote = try! store.create(color: .sky, title: "Weekly plan", body: rich, tags: ["work", "planning", "offsite-2026"])
    let longNote = try! store.create(color: .coral, title: longTitle, body: "- [ ] Short\n" + AttachmentText.token(id: tall.id, isImage: true, label: "A tall tower"),
                                     tags: ["travel"])
    let emptyNote = try! store.create(color: .mint, title: "", body: "")

    @MainActor func editor(_ note: Note, _ presentation: NotePresentation, prepare: ((NoteEditorModel) -> Void)? = nil) -> NoteEditorView {
        let model = NoteEditorModel(note: store.note(id: note.id)!, store: store)
        prepare?(model)
        return NoteEditorView(model: model, presentation: presentation, onClose: {}, onDelete: {}, onTogglePin: {})
    }

    // MARK: Notes

    for (edge, edgeName) in [(ScreenEdge.right, "right"), (.left, "left")] {
        AppSettings.shared.screenEdge = edge
        shoot("note-rich-anchored-\(edgeName)", size: EdgeMetrics.anchoredSize, editor(richNote, .anchored))
    }
    AppSettings.shared.screenEdge = .right
    shoot("note-rich-floating", size: EdgeMetrics.detachedSize, editor(richNote, .detached))
    shoot("note-rich-floating-tall", size: CGSize(width: EdgeMetrics.detachedSize.width, height: 900), editor(richNote, .detached))
    shoot("note-long-title-anchored", size: EdgeMetrics.anchoredSize, editor(longNote, .anchored))
    shoot("note-long-title-floating", size: EdgeMetrics.detachedSize, editor(longNote, .detached))
    shoot("note-empty-anchored", size: EdgeMetrics.anchoredSize, editor(emptyNote, .anchored))
    shoot("note-find", size: EdgeMetrics.detachedSize, editor(richNote, .detached) { model in
        model.toggleFindBar()
        model.findQuery = "the"
    })
    shoot("note-find-none", size: EdgeMetrics.anchoredSize, editor(richNote, .anchored) { model in
        model.toggleFindBar()
        model.findQuery = "zzzz"
    })
    for color in NoteColor.allCases {
        let note = try! store.create(color: color, title: "Colours", body: "- [ ] Task\n- [x] Done\n- Bullet\n1. One\n> Quote\n[a link](https://example.com)",
                                     tags: ["one", "two"])
        shoot("note-color-\(String(describing: color))", size: EdgeMetrics.anchoredSize, editor(note, .anchored))
        DisplayOptions.increaseContrastOverride = true
        shoot("note-color-\(String(describing: color))-contrast", size: EdgeMetrics.anchoredSize, editor(note, .anchored))
        DisplayOptions.increaseContrastOverride = nil
    }
    DisplayOptions.increaseContrastOverride = true
    shoot("note-rich-contrast", size: EdgeMetrics.detachedSize, editor(richNote, .detached))
    DisplayOptions.increaseContrastOverride = nil
    let locked = Note(title: "Bank", body: "\u{26A0}\u{FE0F} " + L("This note could not be decrypted with the key on this Mac."),
                      color: .lilac, state: .active, tags: ["home"], isLocked: true)
    try! store.insert(locked, origin: .local)
    shoot("note-locked", size: EdgeMetrics.anchoredSize, editor(locked, .anchored))
    let daily = try! store.create(color: .butter, title: "Daily 21/10", body: "## Today\n- [ ] ", tags: ["daily"])
    shoot("note-carry-over", size: EdgeMetrics.anchoredSize, editor(daily, .anchored) { model in
        model.carryOverOffer = CarryOverBanner(count: 3, weekday: DailyCarryOver.weekday(of: DailyDay(year: 2026, month: 10, day: 15))) { _ in }
    })

    // MARK: Peek

    shoot("peek-rich", size: EdgeMetrics.previewSize, NotePreviewView(note: store.note(id: richNote.id)!, thumbnail: store.attachmentImage(wide.id)))
    shoot("peek-long-title", size: EdgeMetrics.previewSize, NotePreviewView(note: store.note(id: longNote.id)!, thumbnail: store.attachmentImage(tall.id)))
    shoot("peek-empty", size: EdgeMetrics.previewSize, NotePreviewView(note: store.note(id: emptyNote.id)!))
    shoot("peek-locked", size: EdgeMetrics.previewSize, NotePreviewView(note: locked))

    // MARK: All Notes

    let archived = try! store.create(color: .mint, title: "Old plan", body: "Kept for the record.\n- [x] Done")
    try! store.archive(id: archived.id)
    try! store.setKeepOnDeck(true, id: longNote.id)
    _ = try! store.setPinned(true, id: richNote.id)
    store.setDailyTemplate("# {weekday}, {date}\n\n## Plan\n- [ ] First thing\n- [ ] \n\n## Notes\nWrite here.")
    var actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in }, delete: { _ in }, export: { _ in })
    actions.select = { _ in }
    let windowSize = CGSize(width: 1080, height: 680)
    for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        shoot("allnotes-editing-\(appearanceName)", size: windowSize, appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .default, initialSelection: [richNote.id]))
        shoot("allnotes-none-\(appearanceName)", size: windowSize, appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .default, initialSelection: []))
        shoot("allnotes-multiple-\(appearanceName)", size: windowSize, appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .default, initialSelection: [richNote.id, longNote.id]))
        shoot("allnotes-archived-\(appearanceName)", size: windowSize, appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .library(.archived), initialSelection: [archived.id]))
        shoot("allnotes-locked-\(appearanceName)", size: windowSize, appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .default, initialSelection: [locked.id]))
        shoot("allnotes-template-\(appearanceName)", size: windowSize, appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .library(.daily), initialSelection: [DailyTemplatePane.rowID]))
        shoot("allnotes-minimum-\(appearanceName)", size: CGSize(width: 900, height: 480), appearance: appearance, titled: true, title: L("All Notes"), settle: 1.2,
              AllNotesView(store: store, actions: actions, initialSidebar: .default, initialSelection: [longNote.id]))
        shoot("allnotes-sidebar-\(appearanceName)", size: CGSize(width: 230, height: 460), appearance: appearance,
              AllNotesSidebar(index: TagLibrary.index(store.notes), selection: .constant(.tag("work"))))
    }
    // The pane filling the window (the toolbar's button): the pane alone.
    shoot("allnotes-pane-full", size: windowSize,
          NoteReadingPane(note: store.note(id: richNote.id)!, store: store, actions: actions, onTag: { _ in }))

    // MARK: Settings, as the whole window, every tab

    let settingsWindow = SettingsWindowController(
        settings: AppSettings.shared, sync: FolderSyncService(store: store),
        actions: SettingsActions(chooseSyncFolder: {}, forgetSyncFolder: {}, importNotes: {}, exportAll: {}, showWelcome: {}),
        store: store)
    try! store.backUp(kind: .manual)
    for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        settingsWindow.window.appearance = NSAppearance(named: appearance)
        for tab in SettingsTab.allCases {
            settingsWindow.select(tab)
            shootWindow("settings-\(String(describing: tab))-\(appearanceName)", settingsWindow.window)
        }
    }

    // MARK: Welcome, Archive

    for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        shoot("welcome-\(appearanceName)", size: CGSize(width: 440, height: 724), appearance: appearance, titled: true,
              title: L("Welcome to KeepNote"), WelcomeView(onDone: {}))
        shoot("archive-\(appearanceName)", size: CGSize(width: 560, height: 440), appearance: appearance, titled: true,
              title: L("[noun] Archive"), ArchiveView(store: store, actions: actions))
    }

    // MARK: Notices

    let toast = UndoToastController()
    for (name, message, undo) in [("toast-deleted", Lplural(1, L("Note deleted"), L("%d notes deleted")), true),
                                  ("toast-deleted-many", L("%d notes deleted", 12), true),
                                  ("toast-pin-limit", PinnedDeck.limitMessage, false),
                                  ("toast-brought", AppCoordinator.broughtMessage(DailyCarryOver.Offer(day: DailyDay(year: 2026, month: 10, day: 15), lines: ["- [ ] a", "- [ ] b", "- [ ] c"])), true)] {
        toast.show(message: message, duration: 60, onUndo: undo ? {} : nil)
        if let panel = toast.panelForTesting {
            panel.alphaValue = 1
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                panel.appearance = NSAppearance(named: appearance)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                save("\(name)-\(appearanceName)", panel.contentView!)
            }
        }
        toast.dismiss()
    }

    // MARK: Menus, as text: the titles, for case and punctuation.

    var lines: [String] = []
    @MainActor func dump(_ menu: NSMenu, _ indent: String = "") {
        for item in menu.items {
            lines.append(item.isSeparatorItem ? indent + "—" : indent + item.title + (item.keyEquivalent.isEmpty ? "" : "  [\(item.keyEquivalent)]"))
            if let submenu = item.submenu { dump(submenu, indent + "    ") }
        }
    }
    let probe = MarkdownTextView(frame: .zero)
    lines.append("# Tools"); dump(FormatCommand.makeToolsMenu(target: probe))
    lines.append("# Format"); dump(FormatCommand.makeMenu())
    let coordinator = AppCoordinator(store: store)
    lines.append("# App"); dump(coordinator.makeAppMenu())
    lines.append("# Main"); dump(MainMenu.make(target: coordinator))
    try! lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
    print("wrote menus.txt")
}
