import AppKit
import Combine
import CryptoKit

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

// MARK: - The template's window

@MainActor
func runDailyTemplateWindowTests() {
    let key = SymmetricKey(size: .bits256)
    let store = reopened(scratchDirectory().appendingPathComponent("w.sqlite"), key: key)
    store.setDailyTemplate("# Start\n")
    let before = store.notes.count

    let controller = DailyTemplateWindowController(store: store)
    controller.window.contentView?.layoutSubtreeIfNeeded()
    expect("window: the title is fixed", controller.window.title, "Daily Template")
    expect("window: it opens on the saved text",
           controller.window.contentView.flatMap(textView(in:))?.string, "# Start\n")

    expectTrue("window: typing goes into the editor", type("- [ ] one", into: controller.window))
    controller.flush()
    expect("window: and is saved as the template", store.dailyTemplate.body, "# Start\n- [ ] one")
    expect("window: editing it makes no note", String(store.notes.count), String(before))

    // The note editor's formatting works on it.
    if let body = controller.window.contentView.flatMap(textView(in:)) as? MarkdownTextView {
        body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        body.insertNewline(nil)
        expect("window: Return continues a checklist", body.string, "# Start\n- [ ] one\n- [ ] ")
    } else {
        expectTrue("window: the editor is the note editor", false)
    }

    // A newer template from another Mac shows, once nothing is waiting to be
    // saved: what was just typed is not undone by it.
    _ = store.applyIncomingTemplate(DailyTemplate(body: "too soon", updatedAt: Date().addingTimeInterval(30)))
    spin(0.1)
    expect("window: text still being saved is kept",
           controller.window.contentView.flatMap(textView(in:))?.string, "# Start\n- [ ] one\n- [ ] ")
    controller.flush()
    _ = store.applyIncomingTemplate(DailyTemplate(body: "from elsewhere", updatedAt: Date().addingTimeInterval(60)))
    spin(0.1)
    expect("window: a template that arrives replaces the text",
           controller.window.contentView.flatMap(textView(in:))?.string, "from elsewhere")

    var closed = false
    controller.onClose = { closed = true }
    _ = type("!", into: controller.window)
    controller.close()
    expectTrue("window: closing reports it", closed)
    expect("window: and saves what was typed", store.dailyTemplate.body, "from elsewhere!")
}
