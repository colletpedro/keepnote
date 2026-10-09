import AppKit
import CryptoKit

// MARK: - The edit date, apart from the date sync compares

@MainActor
func runEditedDateTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("edited.sqlite")
    var store: NoteStore? = reopened(database, key: key)
    func pause() { Thread.sleep(forTimeInterval: 0.01) }

    let note = try! store!.create(title: "t", body: "b")
    let archivedOne = try! store!.create(title: "old", body: "b")
    try! store!.archive(id: archivedOne.id)
    let created = store!.note(id: note.id)!
    expectTrue("edited: a new note is edited when it is made", created.editedAt == created.updatedAt)

    // Changes that are not text move the sync date and leave the edit date.
    func untouched(_ name: String, _ change: () -> Void) {
        let before = store!.note(id: note.id)!
        pause()
        change()
        let after = store!.note(id: note.id)!
        expectTrue("edited: \(name) leaves the edit date", after.editedAt == before.editedAt)
        expectTrue("edited: \(name) still moves the sync date", after.updatedAt > before.updatedAt)
    }
    untouched("pinning") { _ = try! store!.setPinned(true, id: note.id) }
    untouched("unpinning") { _ = try! store!.setPinned(false, id: note.id) }
    untouched("keeping") { try! store!.setKeepOnDeck(false, id: note.id) }
    untouched("tags") { try! store!.setTags(["x", "y"], id: note.id) }
    untouched("colour") { try! store!.setColor(.sky, id: note.id) }
    untouched("archiving") { try! store!.archive(id: note.id) }
    untouched("bringing back") { try! store!.unarchive(id: note.id) }

    // Text moves both.
    let beforeText = store!.note(id: note.id)!
    pause()
    try! store!.setBody("changed", id: note.id)
    var after = store!.note(id: note.id)!
    expectTrue("edited: a new body is an edit", after.editedAt > beforeText.editedAt)
    expectTrue("edited: and moves the sync date with it", after.editedAt == after.updatedAt)
    pause()
    try! store!.setTitle("new title", id: note.id)
    expectTrue("edited: a new title is an edit", store!.note(id: note.id)!.editedAt > after.editedAt)
    after = store!.note(id: note.id)!

    // The rules at work change nothing about it.
    let pinnedStore = store!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)
    pinnedStore.now = { clock }
    let stale = try! pinnedStore.create(title: "stale", body: "x")
    let staleEdited = pinnedStore.note(id: stale.id)!.editedAt
    let staleUpdated = pinnedStore.note(id: stale.id)!.updatedAt
    clock = clock.addingTimeInterval(40 * 86_400)
    let archivedIds = try! pinnedStore.archiveStale(days: 30)
    expectTrue("edited: the time rule archived it", archivedIds.contains(stale.id))
    expectTrue("edited: the time rule leaves the edit date", pinnedStore.note(id: stale.id)?.editedAt == staleEdited)
    expectTrue("edited: and the sync date", pinnedStore.note(id: stale.id)?.updatedAt == staleUpdated)
    // The deck keeps the two latest days of dailies; the first one's day is past.
    let daily = try! pinnedStore.create(title: "d", body: "x", tags: ["daily"])
    let dailyEdited = pinnedStore.note(id: daily.id)!.editedAt
    for _ in 0..<2 {
        clock = clock.addingTimeInterval(86_400)
        _ = try! pinnedStore.create(title: "later", body: "x", tags: ["daily"])
    }
    let dailyArchived = try! pinnedStore.archiveDailies()
    expectTrue("edited: the daily rule archived it", dailyArchived.contains(daily.id))
    expectTrue("edited: the daily rule leaves the edit date", pinnedStore.note(id: daily.id)?.editedAt == dailyEdited)

    // Lists sort by it: touching an archived note's pin-like settings does not reorder them.
    let second = try! pinnedStore.create(title: "second", body: "x")
    try! pinnedStore.archive(id: second.id)
    let order = pinnedStore.archivedNotes.map(\.id)
    pause()
    try! pinnedStore.setKeepOnDeck(true, id: archivedOne.id)
    expect("edited: keeping an archived note does not reorder the archive",
           pinnedStore.archivedNotes.map(\.id).map(\.uuidString).joined(separator: ","),
           order.map(\.uuidString).joined(separator: ","))

    // Remembered across launches.
    pause()
    try! pinnedStore.setKeepOnDeck(true, id: note.id)
    let remembered = pinnedStore.note(id: note.id)!
    pinnedStore.waitUntilSaved()
    store = nil
    let again = reopened(database, key: key)
    expectTrue("edited: both dates survive a relaunch",
               abs((again.note(id: note.id)?.editedAt ?? .distantPast).timeIntervalSince(remembered.editedAt)) < 0.001
                && abs((again.note(id: note.id)?.updatedAt ?? .distantPast).timeIntervalSince(remembered.updatedAt)) < 0.001)
    expectTrue("edited: and they are not the same date", remembered.updatedAt > remembered.editedAt)

    // MARK: A database from before the two were apart

    let legacyURL = scratchDirectory().appendingPathComponent("legacy-edited.sqlite")
    let ids: [UUID] = {
        let s = reopened(legacyURL, key: key)
        let ids = [try! s.create(title: "a", body: "b").id, try! s.create(title: "c", body: "d", tags: ["x"]).id]
        s.waitUntilSaved()
        return ids
    }()
    let sync: [UUID: Date] = {
        let s = reopened(legacyURL, key: key)
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, s.note(id: $0)!.updatedAt) })
    }()
    do {
        let db = try! SQLiteDatabase(path: legacyURL.path)
        try! db.execute("ALTER TABLE notes DROP COLUMN edited_at; PRAGMA user_version = 8;")
    }
    let migrated = reopened(legacyURL, key: key)
    migrated.waitUntilSaved()
    expectTrue("edited migration: each note starts edited when it was last updated",
               ids.allSatisfy { abs((migrated.note(id: $0)?.editedAt ?? .distantPast).timeIntervalSince(sync[$0]!)) < 0.001 })
    expectTrue("edited migration: the sync dates do not move",
               ids.allSatisfy { abs((migrated.note(id: $0)?.updatedAt ?? .distantPast).timeIntervalSince(sync[$0]!)) < 0.001 })
    expect("edited migration: the schema is current",
           String(try! SQLiteDatabase(path: legacyURL.path).scalarInt("PRAGMA user_version;")), String(NoteSchema.currentVersion))

    // MARK: The .hmnote file

    let when = Date(timeIntervalSince1970: 1_790_000_000)
    let later = when.addingTimeInterval(3_600)
    let apart = Note(title: "t", body: "b", createdAt: when, updatedAt: later, editedAt: when)
    let text = HMNoteFile(note: apart).serialized()
    expectTrue("edited file: has its own line", text.contains("\nedited: "))
    let parsed = HMNoteFile.parse(text)!
    expectTrue("edited file: round-trips", parsed.note.editedAt == when && parsed.note.updatedAt == later)
    let oldFile = text.components(separatedBy: "\n").filter { !$0.hasPrefix("edited:") }.joined(separator: "\n")
    expectTrue("edited file: an older file has none", HMNoteFile.parse(oldFile)?.editedAt == nil)
    expectTrue("edited file: and reads as edited when it was updated", HMNoteFile.parse(oldFile)?.note.editedAt == later)

    // MARK: The archive package

    let package = try! NoteArchive.encode(notes: [apart])
    let decoded = try! NoteArchive.decode(package)
    expectTrue("edited archive: round-trips", decoded[0].editedAt == when && decoded[0].updatedAt == later)
    let oldArchive = Data("""
    {"format":"com.keepnote.archive","version":1,"exportedAt":"2026-10-01T10:00:00Z","notes":[
      {"id":"\(UUID().uuidString)","title":"t","body":"b","color":1,"state":"active","tags":[],
       "createdAt":"2026-10-01T09:00:00Z","updatedAt":"2026-10-01T10:00:00Z"}]}
    """.utf8)
    let old = try! NoteArchive.decode(oldArchive)
    expectTrue("edited archive: an older archive reads as edited when it was updated", old[0].editedAt == old[0].updatedAt)

    // MARK: Two Macs

    let a = try! NoteStore(databaseURL: scratchDirectory().appendingPathComponent("two.sqlite"), cipher: BodyCipher(key: key))
    let shared = try! a.create(title: "shared", body: "b")
    let held = a.note(id: shared.id)!
    // The other Mac pinned it: newer for sync, same text, and an older KeepNote
    // there would say it was edited just now.
    var pinnedElsewhere = held
    pinnedElsewhere.updatedAt = held.updatedAt.addingTimeInterval(60)
    pinnedElsewhere.editedAt = pinnedElsewhere.updatedAt
    pinnedElsewhere.keepOnDeck = true
    _ = try! a.applyIncoming([pinnedElsewhere])
    expectTrue("edited sync: a change that is not text takes the other copy's settings", a.note(id: shared.id)?.keepOnDeck == true)
    expectTrue("edited sync: and not its edit date", a.note(id: shared.id)?.editedAt == held.editedAt)
    expectTrue("edited sync: but its sync date", a.note(id: shared.id)?.updatedAt == pinnedElsewhere.updatedAt)
    var editedElsewhere = pinnedElsewhere
    editedElsewhere.updatedAt = held.updatedAt.addingTimeInterval(120)
    editedElsewhere.editedAt = editedElsewhere.updatedAt
    editedElsewhere.body = "written on the other Mac"
    _ = try! a.applyIncoming([editedElsewhere])
    expect("edited sync: a text change comes with its text", a.note(id: shared.id)?.body, "written on the other Mac")
    expectTrue("edited sync: and its edit date", a.note(id: shared.id)?.editedAt == editedElsewhere.editedAt)
}
