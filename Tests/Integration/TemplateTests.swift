import AppKit
import Combine
import CryptoKit
import SwiftUI

// MARK: - The daily template: stored, synced, archived — and not a note

func templateFile(in folder: URL) -> DailyTemplate? {
    (try? String(contentsOf: folder.appendingPathComponent(DailyTemplateFile.fileName), encoding: .utf8))
        .flatMap(DailyTemplateFile.parse)
}

@MainActor
func runDailyTemplateStoreTests() {
    let key = SymmetricKey(size: .bits256)
    let directory = scratchDirectory()
    let database = directory.appendingPathComponent("notes.sqlite")

    // MARK: Empty by default, and never a note

    var store: NoteStore? = reopened(database, key: key)
    expect("template: empty by default", store!.dailyTemplate.body, "")
    expectTrue("template: never set", !store!.dailyTemplate.isSet)
    _ = try! store!.create(title: "plain", body: "text", tags: ["work"])
    store!.setDailyTemplate("# Standup\n- [ ] \n")
    expect("template: set", store!.dailyTemplate.body, "# Standup\n- [ ] \n")
    expectTrue("template: now set", store!.dailyTemplate.isSet)
    expect("template: not among the notes", String(store!.notes.count), "1")
    expect("template: not in the notes sync mirrors", String(store!.allNotesForSync().count), "1")
    expect("template: no search finds it", String(store!.search("Standup").count), "0")
    expect("template: no tag counts it", TagText.usage(of: store!.notes.map(\.tags)).map(\.tag).joined(), "work")

    // Typing the same text again is not a change.
    var announced = 0
    let watch = store!.templateChanges.sink { _ in announced += 1 }
    let stamp = store!.dailyTemplate.updatedAt
    store!.setDailyTemplate("# Standup\n- [ ] \n")
    expect("template: the same text announces nothing", String(announced), "0")
    expectTrue("template: and keeps its date", store!.dailyTemplate.updatedAt == stamp)
    store!.setDailyTemplate("# Standup\n- [ ] x\n")
    expect("template: new text is announced once", String(announced), "1")
    expectTrue("template: with a later date", store!.dailyTemplate.updatedAt > stamp)

    // MARK: Stored encrypted, and back at the next launch

    store!.waitUntilSaved()
    let raw = try! SQLiteDatabase(path: database.path).query(
        "SELECT body_ciphertext, nonce FROM daily_template;") { ($0.data(at: 0), $0.data(at: 1)) }
    expect("template: one row", String(raw.count), "1")
    expectTrue("template: the text is not in the file", !raw[0].0.contains(Data("Standup".utf8)))
    let saved = store!.dailyTemplate
    store = nil
    var later: NoteStore? = reopened(database, key: key)
    expect("template: back at the next launch", later!.dailyTemplate.body, "# Standup\n- [ ] x\n")
    expectTrue("template: with its date", abs(later!.dailyTemplate.updatedAt.timeIntervalSince(saved.updatedAt)) < 0.001)
    let wrongKey = reopened(database, key: SymmetricKey(size: .bits256))
    expect("template: unreadable with another key, it reads as empty", wrongKey.dailyTemplate.body, "")
    expect("template: and its notes are untouched", String(wrongKey.notes.count), "1")

    // Emptying it is a change that stays.
    later!.setDailyTemplate("")
    later!.waitUntilSaved()
    later = nil
    let emptied = reopened(database, key: key)
    expect("template: emptied", emptied.dailyTemplate.body, "")
    expectTrue("template: an emptied one still counts as set", emptied.dailyTemplate.isSet)

    // MARK: The latest write wins

    let racer = reopened(scratchDirectory().appendingPathComponent("r.sqlite"), key: key)
    racer.setDailyTemplate("mine")
    let mine = racer.dailyTemplate
    expectTrue("template: an older incoming copy is refused",
               !racer.applyIncomingTemplate(DailyTemplate(body: "old", updatedAt: mine.updatedAt.addingTimeInterval(-60))))
    expect("template: and nothing changes", racer.dailyTemplate.body, "mine")
    expectTrue("template: the same date is refused",
               !racer.applyIncomingTemplate(DailyTemplate(body: "same", updatedAt: mine.updatedAt)))
    expectTrue("template: a newer one is taken",
               racer.applyIncomingTemplate(DailyTemplate(body: "newer", updatedAt: mine.updatedAt.addingTimeInterval(60))))
    expect("template: and shows", racer.dailyTemplate.body, "newer")
    withExtendedLifetime(watch) {}
}

@MainActor
func runDailyTemplateSyncTests() {
    let key = SymmetricKey(size: .bits256)
    let folder = scratchDirectory().appendingPathComponent("Sync", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // MARK: The file

    let file = DailyTemplate(body: "# Day\n\n- [ ] \n\n---\nlast", updatedAt: Date(timeIntervalSince1970: 1_790_000_000.123))
    let parsed = DailyTemplateFile.parse(DailyTemplateFile.serialized(file))
    expect("file: the text round-trips", parsed?.body, file.body)
    expectTrue("file: and the date", parsed.map { abs($0.updatedAt.timeIntervalSince(file.updatedAt)) < 0.001 } ?? false)
    expect("file: an empty template round-trips", DailyTemplateFile.parse(DailyTemplateFile.serialized(DailyTemplate(body: "", updatedAt: file.updatedAt)))?.body, "")
    expectTrue("file: a note file is not a template", DailyTemplateFile.parse(HMNoteFile(note: Note(title: "t", body: "b")).serialized()) == nil)
    expectTrue("file: a template file is not a note", HMNoteFile.parse(DailyTemplateFile.serialized(file)) == nil)
    expectTrue("file: its extension is its own", DailyTemplateFile.fileName.hasSuffix(".hmtemplate"))

    // MARK: Reaches the folder

    let first = reopened(scratchDirectory().appendingPathComponent("a.sqlite"), key: key)
    let sync = FolderSyncService(store: first, folder: folder)
    spin(0.3)
    sync.waitUntilWritten()
    expectTrue("sync: nothing is written for a template never set", templateFile(in: folder) == nil)
    first.setDailyTemplate("# From A")
    spin(0.2)
    sync.waitUntilWritten()
    expect("sync: a set template reaches the folder", templateFile(in: folder)?.body, "# From A")

    // MARK: And the other Mac

    let second = reopened(scratchDirectory().appendingPathComponent("b.sqlite"), key: key)
    let other = FolderSyncService(store: second, folder: folder)
    spin(0.5)
    other.waitUntilWritten()
    spin(0.2)
    expect("sync: another Mac takes it", second.dailyTemplate.body, "# From A")
    expect("sync: and it is no note there", String(second.notes.count), "0")

    // It edits, and the first Mac follows.
    second.setDailyTemplate("# From B")
    spin(0.2)
    other.waitUntilWritten()
    expect("sync: an edit reaches the folder", templateFile(in: folder)?.body, "# From B")
    sync.reconfigure()
    spin(0.5)
    sync.waitUntilWritten()
    spin(0.2)
    expect("sync: and the first Mac follows", first.dailyTemplate.body, "# From B")

    // Emptied, the empty template travels too.
    second.setDailyTemplate("")
    spin(0.2)
    other.waitUntilWritten()
    expect("sync: an emptied template is written", templateFile(in: folder)?.body, "")
    sync.reconfigure()
    spin(0.5)
    sync.waitUntilWritten()
    spin(0.2)
    expect("sync: and the other Mac empties it too", first.dailyTemplate.body, "")

    // A newer one here is not undone by an older file.
    first.setDailyTemplate("newest")
    let newest = first.dailyTemplate
    try! DailyTemplateFile.serialized(DailyTemplate(body: "stale", updatedAt: newest.updatedAt.addingTimeInterval(-3600)))
        .write(to: folder.appendingPathComponent(DailyTemplateFile.fileName), atomically: true, encoding: .utf8)
    sync.reconfigure()
    spin(0.5)
    sync.waitUntilWritten()
    spin(0.2)
    expect("sync: an older file does not win", first.dailyTemplate.body, "newest")
    expect("sync: and the folder is brought up to date", templateFile(in: folder)?.body, "newest")
    withExtendedLifetime((sync, other)) {}
}

@MainActor
func runDailyTemplateArchiveTests() {
    let key = SymmetricKey(size: .bits256)
    let note = Note(title: "n", body: "b", tags: ["x"])
    let template = DailyTemplate(body: "# {weekday}\n- [ ] \n", updatedAt: Date(timeIntervalSince1970: 1_790_000_000))

    let archive = try! NoteArchive.encode(notes: [note], dailyTemplate: template)
    expect("archive: the template round-trips", try! NoteArchive.decodeTemplate(archive)?.body, template.body)
    expectTrue("archive: with its date", (try! NoteArchive.decodeTemplate(archive))?.updatedAt == template.updatedAt)
    expect("archive: the notes are as before", String(try! NoteArchive.decode(archive).count), "1")
    expectTrue("archive: a template never set writes nothing",
               try! NoteArchive.decodeTemplate(NoteArchive.encode(notes: [note], dailyTemplate: .empty)) == nil)
    expectTrue("archive: nor does an export without one",
               !String(data: try! NoteArchive.encode(notes: [note]), encoding: .utf8)!.contains("dailyTemplate"))
    let emptied = try! NoteArchive.encode(notes: [note], dailyTemplate: DailyTemplate(body: "", updatedAt: template.updatedAt))
    expect("archive: an emptied template is kept", try! NoteArchive.decodeTemplate(emptied)?.body, "")
    let old = Data("""
    {"format":"com.keepnote.archive","version":1,"exportedAt":"2026-10-01T10:00:00Z","notes":[]}
    """.utf8)
    expectTrue("archive: an older archive has no template", try! NoteArchive.decodeTemplate(old) == nil)

    // Imported: taken when newer, and an older archive does not undo a newer template.
    let file = scratchDirectory().appendingPathComponent("t.hmnotearchive")
    try! archive.write(to: file)
    let store = reopened(scratchDirectory().appendingPathComponent("i.sqlite"), key: key)
    let result = try! NoteImporter.importContents(of: file, into: store)
    expect("import: the note comes", String(result.applied), "1")
    expect("import: and the template", store.dailyTemplate.body, template.body)
    store.setDailyTemplate("typed after")
    _ = try! NoteImporter.importContents(of: file, into: store)
    expect("import: an older archive does not undo it", store.dailyTemplate.body, "typed after")

    // A folder of files, like the sync folder.
    let folder = scratchDirectory()
    try! DailyTemplateFile.serialized(template).write(to: folder.appendingPathComponent(DailyTemplateFile.fileName), atomically: true, encoding: .utf8)
    let fresh = reopened(scratchDirectory().appendingPathComponent("f.sqlite"), key: key)
    _ = try! NoteImporter.importContents(of: folder, into: fresh)
    expect("import: a folder's template comes too", fresh.dailyTemplate.body, template.body)
    expect("import: and is no note", String(fresh.notes.count), "0")
}

// MARK: - The template's editing model

@MainActor
func runDailyTemplateModelTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("m.sqlite"), key: SymmetricKey(size: .bits256))
    store.setDailyTemplate("# Start\n")
    let model = DailyTemplateModel(store: store)
    expect("model: opens on the saved text", model.text, "# Start\n")

    model.text = "# Start\n- [ ] one"
    model.flush()
    expect("model: typing is saved", store.dailyTemplate.body, "# Start\n- [ ] one")

    // What was just typed is not undone by a version that arrives meanwhile.
    model.text += "\n- [ ] two"
    _ = store.applyIncomingTemplate(DailyTemplate(body: "too soon", updatedAt: Date().addingTimeInterval(30)))
    spin(0.1)
    expect("model: text waiting to be saved is kept", model.text, "# Start\n- [ ] one\n- [ ] two")
    model.flush()
    expect("model: and wins when saved", store.dailyTemplate.body, "# Start\n- [ ] one\n- [ ] two")

    // With nothing waiting, the arriving version shows.
    _ = store.applyIncomingTemplate(DailyTemplate(body: "from elsewhere", updatedAt: Date().addingTimeInterval(120)))
    spin(0.1)
    expect("model: a version that arrives replaces the text", model.text, "from elsewhere")
    expect("model: editing makes no note", String(store.notes.count), "0")
}

// MARK: - Applied only when a new daily is born

@MainActor
func runDailyTemplateApplyTests() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let english = Locale(identifier: "en_US")
    let portuguese = Locale(identifier: "pt_BR")
    var clock = utc.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!   // a Friday
    let store = reopened(scratchDirectory().appendingPathComponent("a.sqlite"), key: SymmetricKey(size: .bits256))
    store.now = { clock }

    // MARK: No template: a blank daily, as before

    let blank = try! store.createDaily(locale: english, calendar: utc)
    expect("apply: no template, no body", blank.note.body, "")
    expect("apply: the title is Daily and the date", blank.note.title, "Daily 10/9")
    expect("apply: tagged daily", blank.note.tags.joined(separator: ","), "daily")
    expect("apply: with today's day", blank.note.dailyDay?.string, "2026-10-09")
    expect("apply: the caret at the start", String(blank.caret), "0")

    // MARK: With one

    store.setDailyTemplate("# {weekday}, {date}\n\n- [ ] \n- [ ] \n")
    clock = clock.addingTimeInterval(86_400)
    let made = try! store.createDaily(locale: portuguese, calendar: utc)
    expect("apply: the variables are filled in", made.note.body, "# sábado, 10/10/2026\n\n- [ ] \n- [ ] \n")
    expect("apply: the title is unchanged", made.note.title, "Daily 10/10")
    expect("apply: the caret is in the first empty item", String(made.caret), "28")
    expect("apply: it is stored that way", store.note(id: made.note.id)?.body, made.note.body)
    expect("apply: the template itself is untouched", store.dailyTemplate.body, "# {weekday}, {date}\n\n- [ ] \n- [ ] \n")

    let english2 = try! store.createDaily(locale: english, calendar: utc)
    expect("apply: in en-US", english2.note.body, "# Saturday, 10/10/26\n\n- [ ] \n- [ ] \n")

    // MARK: Never on an existing note

    let existing = try! store.create(title: "Journal", body: "my own text", tags: ["work"])
    try! store.setTags(["work", "daily"], id: existing.id)
    expect("apply: the daily tag on an existing note leaves its text", store.note(id: existing.id)?.body, "my own text")
    expectTrue("apply: and it is a daily now", store.note(id: existing.id)?.isDaily == true)
    let emptyNote = try! store.create(title: "Empty", body: "", tags: ["daily"])
    expect("apply: nor does creating a note with the tag", emptyNote.body, "")
    let viaDrafts = try! store.create([NoteDraft(title: "Draft", body: "", tags: ["daily"])])
    expect("apply: nor a draft", viaDrafts[0].body, "")
    var imported = Note(title: "Imported", body: "", tags: ["daily"])
    imported.updatedAt = Date()
    _ = try! store.applyIncoming(imported)
    expect("apply: nor an arriving note", store.note(id: imported.id)?.body, "")

    // MARK: Today's Daily that already exists is opened as it is

    try! store.setBody("edited by hand", id: made.note.id)
    store.setDailyTemplate("something else")
    expect("apply: an existing daily of today is found, with its own text",
           DailyNotes.todays(store.notes, today: store.today).map { store.note(id: $0.id)?.body ?? "" }, "edited by hand")

    // MARK: The caret in the note's window

    let fresh = try! store.createDaily(locale: english, calendar: utc)
    let controller = NoteWindowController(note: store.note(id: fresh.note.id)!, store: store, originFrame: nil, cascadeIndex: 0)
    controller.initialCaret = fresh.caret
    controller.show()
    spin(0.3)
    let body = controller.window.contentView.flatMap(textView(in:))
    expect("apply: the window's text is the daily's", body?.string, "something else")
    expect("apply: and the caret is where the template put it", String(body?.selectedRange().location ?? -1), String(fresh.caret))
    controller.close()

    store.setDailyTemplate("- [ ] \n- [ ] second")
    let listed = try! store.createDaily(locale: english, calendar: utc)
    let second = NoteWindowController(note: store.note(id: listed.note.id)!, store: store, originFrame: nil, cascadeIndex: 0)
    second.initialCaret = listed.caret
    second.show()
    spin(0.3)
    expect("apply: the caret in the first empty item",
           String(second.window.contentView.flatMap(textView(in:))?.selectedRange().location ?? -1), "6")
    second.close()

    let plain = NoteWindowController(note: store.note(id: blank.note.id)!, store: store, originFrame: nil, cascadeIndex: 0)
    plain.show()
    spin(0.3)
    expect("apply: without a caret it is the end", String(plain.window.contentView.flatMap(textView(in:))?.selectedRange().location ?? -1), "0")
    plain.close()
}

// MARK: - The template inside All Notes

@MainActor
func runDailyTemplateRowTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("r.sqlite"), key: SymmetricKey(size: .bits256))
    store.setDailyTemplate("# Day\n- [ ] ")
    _ = try! store.create(title: "Daily 09/10", body: "x", tags: ["daily"])
    let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                  delete: { _ in }, export: { _ in })

    func host(selecting: Set<UUID>) -> (NSWindow, NSHostingView<AllNotesView>) {
        let view = AllNotesView(store: store, actions: actions, initialSidebar: .library(.daily), initialSelection: selecting)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        spin(0.5)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Selected: the card shows, with the template in it.
    let (window, hosting) = host(selecting: [DailyTemplatePane.rowID])
    expect("row: the card shows the template", textView(in: hosting)?.string, "# Day\n- [ ] ")
    expect("row: it is no note", String(store.notes.count), "1")
    expect("row: no search finds it", String(store.search("Day").count), "0")
    expect("row: no tag counts it", String(TagLibrary.index(store.notes).tags.count), "1")

    // Typing in the card saves on its own.
    _ = type("one", into: window)
    spin(0.8)
    expect("row: typing saves by itself", store.dailyTemplate.body, "# Day\n- [ ] one")
    expect("row: and makes no note", String(store.notes.count), "1")

    // Not selected: the template is not in the pane.
    let (_, plain) = host(selecting: [])
    expectTrue("row: unselected, no editor", textView(in: plain) == nil)

    // Asked for from outside (a menu, Settings) while All Notes is open on
    // another list: it goes to Daily with the template selected.
    let elsewhere = AllNotesView(store: store, actions: actions, initialSidebar: .library(.all), initialSelection: [])
    let outer = NSHostingView(rootView: elsewhere)
    let outerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
    outerWindow.contentView = outer
    outer.layoutSubtreeIfNeeded()
    spin(0.3)
    expectTrue("row: on another list, no editor", textView(in: outer) == nil)
    NotificationCenter.default.post(name: .keepNoteShowNotesSelection, object: nil,
                                    userInfo: ["selection": NoteSelection.library(.daily).storageValue, "template": true])
    spin(0.5)
    outer.layoutSubtreeIfNeeded()
    spin(0.3)
    expect("row: the menus open the Daily list on the template", textView(in: outer)?.string, "# Day\n- [ ] one")
    outerWindow.contentView = nil
    window.contentView = nil
}

// MARK: - The template's card inside the real All Notes window

/// WCAG contrast ratio of two colours, both read in sRGB.
func contrastRatio(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func channel(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }
    let (l1, l2) = (luminance(a), luminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

@MainActor
func runDailyTemplateLayoutTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("l.sqlite"), key: SymmetricKey(size: .bits256))
    // Long enough to be taller than the pane, so scrolling inside is what keeps it in.
    store.setDailyTemplate((0..<80).map { "- [ ] line \($0)" }.joined(separator: "\n"))
    for index in 0..<4 {
        let date = Date(timeIntervalSinceNow: -3600 * Double(index + 1))
        let note = Note(title: "Daily", body: "Standup", color: .butter, state: .active, tags: ["daily"],
                        createdAt: date, updatedAt: date, dailyDay: DailyDay(Date(timeIntervalSinceNow: -86400 * Double(index))))
        try! store.insert(note, origin: .local)
    }
    let actions = NoteListActions(open: { _ in }, newNote: {}, archive: { _ in }, unarchive: { _ in },
                                  delete: { _ in }, export: { _ in })

    func tables(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        if let table = view as? NSTableView { found.append(table) }
        for sub in view.subviews { found += tables(in: sub) }
        return found
    }

    let cases: [(String, NSAppearance.Name, NSSize)] = [
        ("light, default size", .aqua, NSSize(width: 1080, height: 640)),
        ("dark, default size", .darkAqua, NSSize(width: 1080, height: 640)),
        ("light, minimum size", .aqua, NSSize(width: 900, height: 480)),
        ("dark, minimum size", .darkAqua, NSSize(width: 900, height: 480)),
    ]
    /// The window as the app builds it, off screen, with `selecting` selected.
    func openWindow(_ appearance: NSAppearance.Name, _ size: NSSize, selecting: Set<UUID>) -> HostingWindowController<AllNotesView> {
        let controller = HostingWindowController(
            title: "All Notes", size: size, autosaveName: "KeepNote.Test.\(UUID().uuidString)",
            minSize: NSSize(width: 900, height: 480),
            rootView: AllNotesView(store: store, actions: actions, initialSidebar: .library(.daily), initialSelection: selecting))
        let window = controller.window
        window.appearance = NSAppearance(named: appearance)
        window.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: false)
        // The real orderFrontRegardless, swapped with a no-op by the runner:
        // far off screen, so nothing is seen.
        window.test_orderFrontRegardless()
        spin(1.2)
        window.contentView?.layoutSubtreeIfNeeded()
        spin(0.3)
        return controller
    }

    for (name, appearance, size) in cases {
        // What an ordinary note does to the window is the measure: the
        // template may not ask for more room than that.
        let noteID = store.notes.first!.id
        let reference = openWindow(appearance, size, selecting: [noteID])
        let referenceFrame = reference.window.frame
        reference.window.orderOut(nil)
        reference.window.contentView = nil

        let controller = openWindow(appearance, size, selecting: [DailyTemplatePane.rowID])
        let window = controller.window
        guard let content = window.contentView else { expectTrue("layout (\(name)): a content view", false); continue }

        expect("layout (\(name)): the window is the size an ordinary note leaves it",
               "\(Int(window.frame.width))x\(Int(window.frame.height))", "\(Int(referenceFrame.width))x\(Int(referenceFrame.height))")
        expectTrue("layout (\(name)): the content is no taller than the window",
                   content.frame.height <= window.frame.height + 0.5 && content.frame.width <= window.frame.width + 0.5)

        guard let body = textView(in: content) else { expectTrue("layout (\(name)): the editor is there", false); continue }
        // The editor's scroll view is the card's paper; the text inside it may
        // be as long as it likes.
        let card = (body.enclosingScrollView ?? body).convert((body.enclosingScrollView ?? body).bounds, to: nil)
        let visible = window.contentLayoutRect
        expectTrue("layout (\(name)): the card is below the toolbar", card.maxY <= visible.maxY + 0.5)
        expectTrue("layout (\(name)): and above the bottom edge", card.minY >= visible.minY - 0.5)
        expectTrue("layout (\(name)): and inside the window's width", card.minX >= 0 && card.maxX <= window.frame.width + 0.5)

        let lists = tables(in: content).filter { !$0.isHidden && $0.numberOfRows > 0 }
        let boxes = lists.map { $0.convert($0.bounds, to: nil) }
        expectTrue("layout (\(name)): the sidebar and the list are both there", lists.count >= 2)
        expectTrue("layout (\(name)): each has width", boxes.allSatisfy { $0.width > 0 })
        expectTrue("layout (\(name)): and rows", lists.allSatisfy { $0.numberOfRows > 0 })
        expectTrue("layout (\(name)): the card is in the column to their right", boxes.allSatisfy { card.minX >= $0.maxX - 0.5 })
        expectTrue("layout (\(name)): the lists are inside the window too",
                   boxes.allSatisfy { $0.minX >= -0.5 && $0.maxX <= window.frame.width + 0.5 && $0.maxY <= visible.maxY + 0.5 })

        // Dark or light, the text on the paper is dark on light.
        let ink = (body.typingAttributes[.foregroundColor] as? NSColor) ?? .labelColor
        let paper = NoteColor.default.surface
        var ratio = 0.0
        body.effectiveAppearance.performAsCurrentDrawingAppearance { ratio = contrastRatio(ink, paper) }
        expectTrue("layout (\(name)): the text has 4.5:1 against the paper (\(String(format: "%.1f", ratio)))", ratio >= 4.5)
        expect("layout (\(name)): the editor is drawn in the light appearance",
               body.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue, NSAppearance.Name.aqua.rawValue)

        window.orderOut(nil)
        window.contentView = nil
    }
}
