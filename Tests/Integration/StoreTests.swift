import AppKit
import Combine
import CryptoKit

// MARK: - Fixtures

nonisolated(unsafe) var scratch: [URL] = []

func scratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepnote-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    scratch.append(url)
    return url
}

func removeScratch() {
    scratch.forEach { try? FileManager.default.removeItem(at: $0) }
}

/// Lets queued main-actor work (sync results, change sinks) run.
func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// What a later launch would find in the database.
@MainActor
func reopened(_ url: URL, key: SymmetricKey) -> NoteStore {
    try! NoteStore(databaseURL: url, cipher: BodyCipher(key: key))
}

/// The bytes on disk for a note's body, read past the store.
func rawBody(_ url: URL, id: UUID) -> (ciphertext: Data, nonce: Data, title: String)? {
    let db = try! SQLiteDatabase(path: url.path)
    return try! db.query("SELECT body_ciphertext, nonce, title FROM notes WHERE id = ?;", [.uuid(id)]) {
        ($0.data(at: 0), $0.data(at: 1), $0.string(at: 2))
    }.first
}

func noteFile(in folder: URL, id: UUID) -> HMNoteFile? {
    let url = folder.appendingPathComponent("\(id.uuidString).\(AppPaths.noteFileExtension)")
    return (try? String(contentsOf: url, encoding: .utf8)).flatMap(HMNoteFile.parse)
}

func textView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView, textView.identifier == NoteTextView.bodyIdentifier, !textView.isFieldEditor {
        return textView
    }
    return view.subviews.lazy.compactMap(textView(in:)).first
}

/// Types at the end of an open note's body, the way the keyboard would.
@MainActor
func type(_ text: String, into window: NSWindow) -> Bool {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let body = window.contentView.flatMap(textView(in:)) else { return false }
    body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
    body.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    return true
}

// MARK: - A locked note is never written over

@MainActor
func runLockedNoteTests() {
    let directory = scratchDirectory()
    let database = directory.appendingPathComponent("notes.sqlite")
    let folder = directory.appendingPathComponent("Sync", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let rightKey = SymmetricKey(size: .bits256)

    var store: NoteStore? = reopened(database, key: rightKey)
    let id = try! store!.create(title: "Bank", body: "the secret text", tags: ["home"]).id
    store!.waitUntilSaved()
    store = nil
    let before = rawBody(database, id: id)!

    // Another Mac's key: the body cannot be opened, so the note is locked.
    let locked = reopened(database, key: SymmetricKey(size: .bits256))
    expectTrue("locked: opened with the wrong key", locked.note(id: id)?.isLocked == true)
    let sync = FolderSyncService(store: locked, folder: folder)
    try! locked.setBody("typed over the placeholder", id: id)
    try! locked.setTitle("renamed", id: id)
    try! locked.update(id: id) { $0.body = "and again"; $0.title = "and again" }
    try! locked.setColor(.mint, id: id)
    try! locked.setTags(["work"], id: id)
    try! locked.archive(id: id)
    try! locked.unarchive(id: id)
    try! locked.move(id: id, to: 0)
    locked.waitUntilSaved()
    spin(0.3)
    sync.waitUntilWritten()

    let after = rawBody(database, id: id)!
    expectTrue("locked: ciphertext untouched", after.ciphertext == before.ciphertext)
    expectTrue("locked: nonce untouched", after.nonce == before.nonce)
    expect("locked: title untouched", after.title, "Bank")
    expect("locked: metadata still saved", locked.note(id: id)?.tags.joined(separator: ","), "work")
    expectTrue("locked: never written to the sync folder", noteFile(in: folder, id: id) == nil)

    let restored = reopened(database, key: rightKey)
    expect("locked: the right key still opens it", restored.note(id: id)?.body, "the secret text")
    expectTrue("locked: and it is not locked there", restored.note(id: id)?.isLocked == false)
}

// MARK: - The last edit survives closing the note and quitting

@MainActor
func runLastEditTests() {
    let key = SymmetricKey(size: .bits256)

    // Closing the note with the autosave still pending.
    do {
        let database = scratchDirectory().appendingPathComponent("notes.sqlite")
        let store = reopened(database, key: key)
        let note = try! store.create(title: "Close", body: "start")
        let controller = NoteWindowController(note: note, store: store, originFrame: nil, cascadeIndex: 0)
        expectTrue("close: typed into the note", type(" typed last", into: controller.window))
        expect("close: still waiting on the autosave", store.note(id: note.id)?.body, "start")
        controller.close()
        store.waitUntilSaved()
        expect("close: written on close", reopened(database, key: key).note(id: note.id)?.body, "start typed last")
    }

    // Quitting with the autosave still pending: what applicationWillTerminate
    // runs, and nothing after it — the process is gone.
    do {
        let database = scratchDirectory().appendingPathComponent("notes.sqlite")
        let store = reopened(database, key: key)
        let note = try! store.create(title: "Quit", body: "start")
        let coordinator = AppCoordinator(store: store)
        coordinator.open(noteID: note.id, from: nil)
        guard let window = NSApp.windows.compactMap({ $0 as? NoteWindow }).last else {
            expectTrue("quit: note window opened", false)
            return
        }
        expectTrue("quit: typed into the note", type(" typed last", into: window))
        expect("quit: still waiting on the autosave", store.note(id: note.id)?.body, "start")
        coordinator.finishWriting()
        expect("quit: on disk before the process ends", reopened(database, key: key).note(id: note.id)?.body, "start typed last")
        coordinator.flushEverything()
        NSApp.windows.compactMap { $0 as? NoteWindow }.forEach { $0.orderOut(nil) }
    }

    // A burst of edits queued behind each other, then quit.
    do {
        let database = scratchDirectory().appendingPathComponent("notes.sqlite")
        let store = reopened(database, key: key)
        let notes = try! store.create((0..<50).map { NoteDraft(title: "n\($0)", body: "") })
        for (index, note) in notes.enumerated() { try! store.setBody("final \(index)", id: note.id) }
        store.waitUntilSaved()
        let disk = reopened(database, key: key)
        expectTrue("quit: every queued edit is on disk",
                   notes.enumerated().allSatisfy { disk.note(id: $1.id)?.body == "final \($0)" })
    }
}

// MARK: - The latest write wins

@MainActor
func runLatestWriteTests() {
    let key = SymmetricKey(size: .bits256)
    let directory = scratchDirectory()
    let database = directory.appendingPathComponent("notes.sqlite")
    let folder = directory.appendingPathComponent("Sync", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = reopened(database, key: key)
    let sync = FolderSyncService(store: store, folder: folder)
    spin(0.2)

    let note = try! store.create(title: "Race", body: "v0")
    for version in 1...200 { try! store.setBody("v\(version)", id: note.id) }
    store.waitUntilSaved()
    sync.waitUntilWritten()
    expect("latest: in memory", store.note(id: note.id)?.body, "v200")
    expect("latest: in the database", reopened(database, key: key).note(id: note.id)?.body, "v200")
    expect("latest: in the sync folder", noteFile(in: folder, id: note.id)?.body, "v200")

    // Created in a batch and edited straight away: the edit is queued after
    // the insert and is what stays.
    let batch = try! store.create([NoteDraft(body: "a"), NoteDraft(body: "b")])
    try! store.setBody("b edited", id: batch[1].id)
    store.waitUntilSaved()
    expect("latest: an edit right after a batch insert", reopened(database, key: key).note(id: batch[1].id)?.body, "b edited")

    // An older copy from the folder loses to the newer one here.
    var older = store.note(id: note.id)!
    older.body = "stale"
    older.updatedAt = older.updatedAt.addingTimeInterval(-60)
    expectTrue("latest: an older incoming copy is refused", (try? store.applyIncoming(older)) == false)
    store.waitUntilSaved()
    expect("latest: and nothing on disk changes", reopened(database, key: key).note(id: note.id)?.body, "v200")

    // A newer one wins.
    var newer = store.note(id: note.id)!
    newer.body = "from the other Mac"
    newer.updatedAt = newer.updatedAt.addingTimeInterval(60)
    expectTrue("latest: a newer incoming copy is taken", (try? store.applyIncoming(newer)) == true)
    store.waitUntilSaved()
    expect("latest: and saved", reopened(database, key: key).note(id: note.id)?.body, "from the other Mac")
    withExtendedLifetime(sync) {}
}

// MARK: - Many notes, one transaction, one change

@MainActor
func runBatchTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("notes.sqlite")
    let store = reopened(database, key: key)
    var events: [StoreChange] = []
    var publishes = 0
    let changes = store.changes.sink { events.append($0.0) }
    let published = store.$notes.dropFirst().sink { _ in publishes += 1 }

    let created = try! store.create((0..<50).map { NoteDraft(title: "n\($0)") })
    expect("batch: one change for fifty notes", String(events.count), "1")
    expect("batch: one redraw", String(publishes), "1")
    expectTrue("batch: the last created is on top", store.notes.first?.id == created.last?.id)
    expectTrue("batch: colours still walk the palette", created[0].color.next == created[1].color)

    events.removeAll()
    publishes = 0
    let imported = (0..<30).map { Note(title: "i\($0)", body: "x") }
    let applied = try! store.applyIncoming(imported, origin: .importer)
    expect("import: thirty applied", String(applied.count), "30")
    expect("import: one change", String(events.count), "1")
    expect("import: one redraw", String(publishes), "1")
    store.waitUntilSaved()
    expect("import: all on disk", String(reopened(database, key: key).notes.count), "80")
    withExtendedLifetime((changes, published)) {}
}

// MARK: - Sync writes what changed, and not its own echo

@MainActor
func runSyncWriteTests() {
    let key = SymmetricKey(size: .bits256)
    let directory = scratchDirectory()
    let folder = directory.appendingPathComponent("Sync", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let database = directory.appendingPathComponent("notes.sqlite")
    var store: NoteStore? = reopened(database, key: key)
    let notes = try! store!.create((0..<20).map { NoteDraft(title: "s\($0)", body: "body \($0)") })
    store!.waitUntilSaved()
    store = nil

    let synced = reopened(database, key: key)
    var sync: FolderSyncService? = FolderSyncService(store: synced, folder: folder)
    spin(0.5)
    sync!.waitUntilWritten()
    expect("sync: every note reaches an empty folder", String(notes.filter { noteFile(in: folder, id: $0.id) != nil }.count), "20")

    func modificationDates() -> [Date?] {
        notes.map { FileStamps.modificationDate(of: folder.appendingPathComponent("\($0.id.uuidString).\(AppPaths.noteFileExtension)")) }
    }
    let written = modificationDates()
    var incoming = 0
    let watch = synced.changes.sink { if $0.1 == .sync { incoming += 1 } }

    // A reorder is a `.reloaded`: nothing in the files changed.
    try! synced.move(id: notes[3].id, to: 10)
    spin(0.3)
    sync!.waitUntilWritten()
    expectTrue("sync: a reorder rewrites no file", modificationDates() == written)

    // One edit, one file; and the write coming back is not applied.
    try! synced.setBody("edited", id: notes[5].id)
    synced.waitUntilSaved()
    sync!.waitUntilWritten()
    spin(1.0)
    let after = modificationDates()
    expect("sync: one edit rewrites one file",
           String(zip(written, after).filter { $0 != $1 }.count), "1")
    expect("sync: the edit is in the file", noteFile(in: folder, id: notes[5].id)?.body, "edited")
    expect("sync: its own write is not applied back", String(incoming), "0")

    // Restarting sync reads the folder and writes nothing it already holds.
    // The folder's dates are only kept to the millisecond, which is what the
    // comparison has to allow for — while edits less than a millisecond
    // apart (the 200 above) must still each be written.
    sync = nil
    sync = FolderSyncService(store: synced, folder: folder)
    spin(0.5)
    sync!.waitUntilWritten()   // the folder read
    spin(0.3)                  // applied, then what is newer here queued
    sync!.waitUntilWritten()
    expectTrue("sync: starting again rewrites no file", modificationDates() == after)

    // A file changed by someone else is still picked up.
    var remote = noteFile(in: folder, id: notes[7].id)!
    remote.body = "from the other Mac"
    remote.updatedAt = Date().addingTimeInterval(5)
    try! remote.serialized().write(to: folder.appendingPathComponent(remote.fileName), atomically: true, encoding: .utf8)
    sync!.reconfigure()
    spin(0.5)
    sync!.waitUntilWritten()
    spin(0.2)
    expect("sync: another writer's change still arrives", synced.note(id: notes[7].id)?.body, "from the other Mac")
    withExtendedLifetime(watch) {}
}

// MARK: - Display text, worked out once per change

func runDerivedTextTests() {
    /// What `displayTitle` was before it was cached: the whole body stripped.
    func reference(_ title: String, _ body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let line = MarkdownText.plain(body).split(separator: "\n", omittingEmptySubsequences: true).first
            .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line, !line.isEmpty { return line }
        return "Untitled"
    }
    let bodies = [
        "", "\n\n", "   \nsecond", "# Heading\nrest", "---\n\n**Bold** start", "```\ncode first\n```\nafter",
        "| a | b |\n|---|---|\n| 1 | 2 |", "| | |\nnext", "- [ ] task\nmore", "> quote", "%%hidden%%\nshown",
        "  \n\t\n[[Page|Alias]] link", "~~~\n\n~~~\nx",
    ]
    for body in bodies {
        expect("display title of \(body.debugDescription)", Note(body: body).displayTitle, reference("", body))
    }
    expect("display title: the title wins", Note(title: "  Mine ", body: "# Other").displayTitle, "Mine")

    var note = Note(title: "", body: "# First\nrest of it")
    expect("display title: from the body", note.displayTitle, "First")
    expect("preview: without the title line", note.preview, "rest of it")
    let copy = note
    note.body = "# Second\nother"
    expect("display title: follows a body change", note.displayTitle, "Second")
    expect("preview: follows a body change", note.preview, "other")
    expect("display title: a copy keeps its own", copy.displayTitle, "First")
    note.title = "Titled"
    expect("display title: follows a title change", note.displayTitle, "Titled")
    expectTrue("equality ignores the cache", Note(id: copy.id, title: copy.title, body: copy.body,
        color: copy.color, state: copy.state, sortIndex: copy.sortIndex, tags: copy.tags,
        createdAt: copy.createdAt, updatedAt: copy.updatedAt) == copy)
}

// MARK: - Daily notes: the day a note received the tag

@MainActor
func runDailyDayStoreTests() {
    let key = SymmetricKey(size: .bits256)
    let directory = scratchDirectory()
    let database = directory.appendingPathComponent("notes.sqlite")
    var calendar = Calendar.current
    calendar.timeZone = .current
    var clock = Date(timeIntervalSince1970: 1_790_000_000)
    func dayString(_ date: Date) -> String { DailyDay(date).string }

    var store: NoteStore? = reopened(database, key: key)
    store!.now = { clock }
    let day1 = dayString(clock)
    let plain = try! store!.create(title: "plain", body: "x", tags: ["work"])
    let born = try! store!.create(title: "born daily", body: "x", tags: ["daily"])
    expect("daily: a note created with the tag has today", born.dailyDay?.string, day1)
    expect("daily: an ordinary note has no day", plain.dailyDay?.string, nil)

    try! store!.setTags(["work", "daily"], id: plain.id)
    expect("daily: receiving the tag grants today", store!.note(id: plain.id)?.dailyDay?.string, day1)

    clock = clock.addingTimeInterval(3 * 86_400)
    let day2 = dayString(clock)
    expectTrue("daily: the clock moved a day", day1 != day2)
    try! store!.setBody("edited", id: plain.id)
    try! store!.setTags(["daily", "other"], id: plain.id)
    expect("daily: the day does not change afterwards", store!.note(id: plain.id)?.dailyDay?.string, day1)

    try! store!.setTags(["other"], id: plain.id)
    expect("daily: taking the tag off clears the day", store!.note(id: plain.id)?.dailyDay?.string, nil)
    try! store!.setTags(["other", "daily"], id: plain.id)
    expect("daily: putting it back grants the day of today", store!.note(id: plain.id)?.dailyDay?.string, day2)

    try! store!.update(id: born.id) { $0.dailyKept = true }
    store!.waitUntilSaved()
    store = nil

    let again = reopened(database, key: key)
    expect("daily: the day is in the database", again.note(id: born.id)?.dailyDay?.string, day1)
    expect("daily: and the mark", String(again.note(id: born.id)?.dailyKept ?? false), "true")
    expect("daily: and a later day", again.note(id: plain.id)?.dailyDay?.string, day2)
    expect("daily: ordinary notes still have none", again.note(id: plain.id)?.dailyKept == false ? "none" : "kept", "none")
    try! again.setTags([], id: born.id)
    expect("daily: losing the tag clears the mark too", String(again.note(id: born.id)?.dailyKept ?? true), "false")

    // MARK: The .hmnote file

    let withDay = Note(title: "t", body: "b", tags: ["daily"], dailyDay: DailyDay(string: "2026-10-02"), dailyKept: true)
    let text = HMNoteFile(note: withDay).serialized()
    expectTrue("file: the day is a header line", text.contains("\ndaily: 2026-10-02\n"))
    let parsed = HMNoteFile.parse(text)
    expect("file: the day round-trips", parsed?.dailyDay?.string, "2026-10-02")
    expect("file: and the mark", String(parsed?.dailyKept ?? false), "true")
    expect("file: and reaches the note", parsed?.note.dailyDay?.string, "2026-10-02")
    let ordinary = HMNoteFile(note: Note(title: "o", body: "b", tags: ["x"])).serialized()
    expectTrue("file: an ordinary note writes no daily line", !ordinary.contains("daily"))
    let old = """
    --- keepnote ---
    schema: 1
    id: \(UUID().uuidString)
    title: old
    color: 1
    state: active
    tags: daily
    created: 2026-10-01T10:00:00.000Z
    updated: 2026-10-01T10:00:00.000Z
    ---

    from an older KeepNote
    """
    let legacy = HMNoteFile.parse(old)
    expectTrue("file: an older file parses", legacy != nil)
    expect("file: and has no day", legacy?.dailyDay?.string, nil)
    expect("file: nor a mark", String(legacy?.dailyKept ?? true), "false")
    expect("file: a day in a daily line that is not a day is ignored",
           HMNoteFile.parse(old.replacingOccurrences(of: "tags: daily", with: "tags: daily\ndaily: soon"))?.dailyDay?.string, nil)

    // A daily from such a file is given today when it arrives.
    let receiver = reopened(scratchDirectory().appendingPathComponent("r.sqlite"), key: key)
    receiver.now = { clock }
    _ = try! receiver.applyIncoming(legacy!.note)
    expect("file: an older daily arrives with today", receiver.note(id: legacy!.id)?.dailyDay?.string, dayString(clock))
    var notDaily = HMNoteFile(note: Note(title: "n", body: "b", tags: ["x"]))
    notDaily.dailyDay = DailyDay(string: "2026-10-02")
    _ = try! receiver.applyIncoming(notDaily.note)
    expect("file: a day without the tag is dropped on arrival", receiver.note(id: notDaily.id)?.dailyDay?.string, nil)

    // MARK: The archive package

    let archived = try! NoteArchive.encode(notes: [withDay, Note(title: "o", body: "b", tags: ["x"])])
    let decoded = try! NoteArchive.decode(archived)
    expect("archive: the day round-trips", decoded[0].dailyDay?.string, "2026-10-02")
    expect("archive: and the mark", String(decoded[0].dailyKept), "true")
    expect("archive: an ordinary note has none", decoded[1].dailyDay?.string, nil)
    let json = String(data: archived, encoding: .utf8)!
    expectTrue("archive: an ordinary note writes no daily key", json.components(separatedBy: "dailyDay").count == 2)
    let oldArchive = Data("""
    {"format":"com.keepnote.archive","version":1,"exportedAt":"2026-10-01T10:00:00Z","notes":[
      {"id":"\(UUID().uuidString)","title":"t","body":"b","color":1,"state":"active","tags":["daily"],
       "createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z"}]}
    """.utf8)
    expect("archive: an older archive still decodes", String((try? NoteArchive.decode(oldArchive))?.count ?? -1), "1")

    // MARK: A database from before dailies

    let legacyURL = scratchDirectory().appendingPathComponent("legacy.sqlite")
    let legacyID: UUID = {
        let store = reopened(legacyURL, key: key)
        let id = try! store.create(title: "tagged before", body: "b", tags: ["daily"]).id
        _ = try! store.create(title: "other", body: "b", tags: ["x"])
        store.waitUntilSaved()
        return id
    }()
    do {
        let db = try! SQLiteDatabase(path: legacyURL.path)
        try! db.execute("ALTER TABLE notes DROP COLUMN edited_at; ALTER TABLE notes DROP COLUMN daily_day; ALTER TABLE notes DROP COLUMN daily_kept; ALTER TABLE notes DROP COLUMN keep_on_deck; ALTER TABLE notes DROP COLUMN pinned_at; ALTER TABLE notes DROP COLUMN last_opened_day; ALTER TABLE notes DROP COLUMN auto_archived_day; PRAGMA user_version = 3;")
    }
    let migrated = reopened(legacyURL, key: key)
    migrated.waitUntilSaved()
    expect("migration: both notes survive", String(migrated.notes.count), "2")
    expect("migration: a note already tagged daily is given a day", migrated.note(id: legacyID)?.dailyDay == nil ? "none" : "day", "day")
    expect("migration: and it is saved", reopened(legacyURL, key: key).note(id: legacyID)?.dailyDay == nil ? "none" : "day", "day")
    expect("migration: the edit date is untouched",
           String(migrated.note(id: legacyID)?.updatedAt == reopened(legacyURL, key: key).note(id: legacyID)?.updatedAt), "true")
    let version = try! SQLiteDatabase(path: legacyURL.path).scalarInt("PRAGMA user_version;")
    expect("migration: the schema is current", String(version), String(NoteSchema.currentVersion))
}

// MARK: - Daily notes: the archive rule on the real store

@MainActor
func runDailyRuleStoreTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("notes.sqlite")
    var clock = Date(timeIntervalSince1970: 1_790_000_000)
    func make(_ store: NoteStore) { store.now = { clock } }

    var store: NoteStore? = reopened(database, key: key)
    make(store!)
    var dailies: [Note] = []
    for _ in 0..<4 {
        dailies.append(try! store!.create(title: "d", body: "b", tags: ["daily"]))
        clock = clock.addingTimeInterval(86_400)
    }
    let ordinary = try! store!.create(title: "plain", body: "b", tags: ["work"])
    var arrivals = 0
    let watch = store!.dailyArrived.sink { arrivals += 1 }
    let third = try! store!.create(title: "e", body: "b", tags: ["daily"])
    expect("rule: a note created as a daily announces it", String(arrivals), "1")
    try! store!.setTags(["daily"], id: ordinary.id)
    expect("rule: so does one that receives the tag", String(arrivals), "2")
    try! store!.setTags(["daily", "x"], id: ordinary.id)
    expect("rule: a later edit does not", String(arrivals), "2")
    try! store!.delete(id: third.id)
    try! store!.purge(id: third.id)
    // Days: d0..d3 are four different days, `ordinary` (now a daily) and
    // `third` fall on the fifth.
    let edited = store!.note(id: dailies[0].id)!.updatedAt
    let open: Set<UUID> = [dailies[1].id]
    let archived = try! store!.archiveDailies(open: open)
    expect("rule: the old ones go, except the one that is open",
           Set(archived).map(\.uuidString).sorted().joined(separator: ","), [dailies[0].id, dailies[2].id].map(\.uuidString).sorted().joined(separator: ","))
    expectTrue("rule: archived, not deleted", store!.note(id: dailies[0].id)?.state == .archived && store!.note(id: dailies[0].id)?.deletedAt == nil)
    expectTrue("rule: the edit date is untouched", store!.note(id: dailies[0].id)?.updatedAt == edited)
    expectTrue("rule: the open one waits", store!.note(id: dailies[1].id)?.state == .active)
    expectTrue("rule: the recent days stay", store!.note(id: dailies[3].id)?.state == .active && store!.note(id: ordinary.id)?.state == .active)
    expect("rule: a second run does nothing", String(try! store!.archiveDailies(open: open).count), "0")
    let later = try! store!.archiveDailies(open: [])
    expect("rule: closed, it goes", later.map(\.uuidString).joined(separator: ","), dailies[1].id.uuidString)

    // Brought back by hand: it stays.
    try! store!.unarchive(id: dailies[0].id)
    expectTrue("keep: restoring an old daily remembers it", store!.note(id: dailies[0].id)?.dailyKept == true)
    expect("keep: the rule leaves it", String(try! store!.archiveDailies().count), "0")
    expectTrue("keep: and it is on the deck", store!.note(id: dailies[0].id)?.state == .active)
    try! store!.unarchive(id: dailies[1].id)
    try! store!.archive(id: dailies[1].id)
    try! store!.toggleArchive(id: dailies[1].id)
    expect("keep: toggling it back counts too", String(store!.note(id: dailies[1].id)?.dailyKept ?? false), "true")
    store!.waitUntilSaved()
    store = nil

    let again = reopened(database, key: key)
    make(again)
    expectTrue("keep: remembered across launches", again.note(id: dailies[0].id)?.dailyKept == true)
    expect("rule: a new launch changes nothing", String(try! again.archiveDailies().count), "0")
    expectTrue("rule: archived stays archived across launches", again.note(id: dailies[2].id)?.state == .archived)

    // A recent day restored is not remembered, so it ages out with its day.
    try! again.archive(id: ordinary.id)
    try! again.unarchive(id: ordinary.id)
    expectTrue("keep: restoring a recent daily remembers nothing", again.note(id: ordinary.id)?.dailyKept == false)
    withExtendedLifetime(watch) {}

    // Two Macs, same notes: same result.
    let a = reopened(scratchDirectory().appendingPathComponent("a.sqlite"), key: key)
    let b = reopened(scratchDirectory().appendingPathComponent("b.sqlite"), key: key)
    var days = Date(timeIntervalSince1970: 1_790_000_000)
    var fresh: [Note] = []
    for index in 0..<6 {
        fresh.append(Note(title: "m\(index)", body: "b", tags: ["daily"], dailyDay: DailyDay(days)))
        days = days.addingTimeInterval(86_400)
    }
    _ = try! a.applyIncoming(fresh, origin: .importer)
    _ = try! b.applyIncoming(fresh.reversed(), origin: .importer)
    _ = try! a.archiveDailies()
    _ = try! b.archiveDailies()
    _ = try! b.archiveDailies()
    func archivedIDs(_ store: NoteStore) -> [String] { store.notes.filter { $0.state == .archived }.map(\.id.uuidString).sorted() }
    expect("two Macs: four archived", String(archivedIDs(a).count), "4")
    expectTrue("two Macs: the same four", archivedIDs(a) == archivedIDs(b))
    expect("two Macs: nothing deleted", String(a.notes.count), "6")
}

// MARK: - Daily notes: as many as you like on one day

@MainActor
func runManyDailiesTests() {
    let key = SymmetricKey(size: .bits256)
    let store = reopened(scratchDirectory().appendingPathComponent("notes.sqlite"), key: key)
    var clock = Date(timeIntervalSince1970: 1_790_000_000)
    store.now = { clock }

    // An older day, then a day with sixty notes that each simply got the tag.
    let older = try! store.create(title: "yesterday", body: "b", tags: ["daily"])
    clock = clock.addingTimeInterval(86_400)
    let ordinary = try! store.create((0..<60).map { NoteDraft(title: "n\($0)", body: "b", tags: ["work"]) })
    var ids = Set<UUID>()
    for note in ordinary {
        try! store.setTags(note.tags + ["daily"], id: note.id)
        ids.insert(note.id)
    }
    let days = Set(ordinary.compactMap { store.note(id: $0.id)?.dailyDay })
    expect("many: sixty dailies, one day", String(days.count), "1")
    expect("many: all with today's day", days.first?.string, DailyDay(clock).string)
    expect("many: none is archived by the rule", String(try! store.archiveDailies().count), "0")

    // Today's Daily opens the one edited last.
    try! store.setBody("latest", id: ordinary[17].id)
    expect("many: today's daily is the one edited last", DailyNotes.todays(store.notes, today: store.today)?.id.uuidString, ordinary[17].id.uuidString)

    // Two more days later the old one goes, and the sixty with their day stay
    // while they are one of the two latest.
    clock = clock.addingTimeInterval(86_400)
    let third = try! store.create(title: "third", body: "b", tags: ["daily"])
    expect("many: a third day archives the first only", try! store.archiveDailies().map(\.uuidString).joined(separator: ","), older.id.uuidString)
    expectTrue("many: the sixty are on the deck", ordinary.allSatisfy { store.note(id: $0.id)?.state == .active })
    clock = clock.addingTimeInterval(86_400)
    _ = try! store.create(title: "fourth", body: "b", tags: ["daily"])
    expect("many: a fourth archives all sixty, deletes none",
           "\(try! store.archiveDailies().count) \(store.notes.count)", "60 63")
    expectTrue("many: the latest two days remain", store.note(id: third.id)?.state == .active)
}

// MARK: - Daily notes: archived dailies live under Daily, not in the archive

@MainActor
func runDailyArchiveSearchTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("notes.sqlite"), key: SymmetricKey(size: .bits256))
    let daily = try! store.create(title: "Daily 08/10", body: "standup", tags: ["daily"])
    let plain = try! store.create(title: "Plan", body: "standup", tags: ["work"])
    try! store.archive(id: daily.id)
    try! store.archive(id: plain.id)
    expect("archive: only the ordinary note is in the archive",
           store.search("", scope: .archived).map(\.id.uuidString).joined(separator: ","), plain.id.uuidString)
    expect("archive: and found there by its text", String(store.search("standup", scope: .archived).count), "1")
    expect("archive: the archived list leaves the daily out", store.archivedNotes.map(\.id.uuidString).joined(separator: ","), plain.id.uuidString)
    expect("archive: All still finds both", String(store.search("standup", scope: .all).count), "2")
    expect("archive: the daily is archived all the same", store.note(id: daily.id)?.state == .archived ? "yes" : "no", "yes")
}

// MARK: - Daily notes: the introduction

@MainActor
func runDailyIntroTests() {
    expect("intro: the words", DailyIntro.text,
           "Daily notes. Add the daily tag to any note, as many as you like per day. Notes from your two most recent days stay on the deck. Older ones are archived automatically and kept here. You can set a template for new daily notes.")
    let defaults = UserDefaults(suiteName: "keepnote-intro-\(UUID().uuidString)")!
    let settings = AppSettings(defaults: defaults)
    expect("intro: not seen at first", String(settings.dailyIntroSeen), "false")
    settings.dailyIntroSeen = true
    expect("intro: once dismissed it stays dismissed", String(AppSettings(defaults: defaults).dailyIntroSeen), "true")
}

// MARK: - Daily notes: opening an archived daily leaves it in the archive

@MainActor
func runOpenArchivedDailyTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("notes.sqlite"), key: SymmetricKey(size: .bits256))
    let note = try! store.create(title: "Daily 01/10", body: "old", tags: ["daily"])
    try! store.archive(id: note.id)
    let archived = store.note(id: note.id)!
    let controller = NoteWindowController(note: archived, store: store, originFrame: nil, cascadeIndex: 0)
    controller.show()
    spin(0.3)
    expectTrue("open archived: still archived with the window on screen", store.note(id: note.id)?.state == .archived)
    expectTrue("open archived: not on the deck", !store.activeNotes.contains { $0.id == note.id })
    expectTrue("open archived: the edit date is untouched", store.note(id: note.id)?.updatedAt == archived.updatedAt)
    controller.close()
    spin(0.6)
    expectTrue("open archived: and still archived once closed", store.note(id: note.id)?.state == .archived)
}

// MARK: - A note opens on the screen the cursor is on

@MainActor
func runNoteScreenTests() {
    let screens = NSScreen.screens
    guard let first = screens.first else { return }
    let inside = NSPoint(x: first.frame.midX, y: first.frame.midY)
    expectTrue("screen: the one holding the cursor", NoteWindowController.screen(containing: inside, in: screens)?.frame == first.frame)
    expectTrue("screen: none when the cursor is off every screen",
               NoteWindowController.screen(containing: NSPoint(x: first.frame.minX - 50_000, y: 0), in: screens) == nil)
    if screens.count > 1 {
        let other = screens[1]
        expectTrue("screen: the second screen when the cursor is on it",
                   NoteWindowController.screen(containing: NSPoint(x: other.frame.midX, y: other.frame.midY), in: screens)?.frame == other.frame)
    }
}
