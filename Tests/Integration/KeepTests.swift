import AppKit
import CryptoKit

// MARK: - Keep on Deck, pins and the time rule on the real store

@MainActor
func runKeepOnDeckTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("keep.sqlite")
    var store: NoteStore? = reopened(database, key: key)
    let note = try! store!.create(title: "keep me", body: "x")
    let other = try! store!.create(title: "other", body: "y")
    expect("keep: off by default", String(note.keepOnDeck), "false")

    try! store!.setKeepOnDeck(true, id: note.id)
    expect("keep: turned on", String(store!.note(id: note.id)?.keepOnDeck ?? false), "true")
    expect("keep: only that note", String(store!.note(id: other.id)?.keepOnDeck ?? true), "false")
    store!.waitUntilSaved()
    store = nil

    let again = reopened(database, key: key)
    expect("keep: remembered across launches", String(again.note(id: note.id)?.keepOnDeck ?? false), "true")
    try! again.setKeepOnDeck(false, id: note.id)
    expect("keep: turned off", String(again.note(id: note.id)?.keepOnDeck ?? true), "false")

    // The .hmnote file.
    let kept = Note(title: "t", body: "b", keepOnDeck: true)
    let text = HMNoteFile(note: kept).serialized()
    expectTrue("keep file: a header line", text.contains("\nkeep: yes\n"))
    expect("keep file: round-trips", String(HMNoteFile.parse(text)?.keepOnDeck ?? false), "true")
    expect("keep file: reaches the note", String(HMNoteFile.parse(text)?.note.keepOnDeck ?? false), "true")
    expectTrue("keep file: an ordinary note writes none",
               !HMNoteFile(note: Note(title: "o", body: "b")).serialized().contains("keep:"))
    expect("keep file: and reads as off", String(HMNoteFile.parse(HMNoteFile(note: Note(title: "o", body: "b")).serialized())?.keepOnDeck ?? true), "false")

    // The archive package.
    let archive = try! NoteArchive.encode(notes: [kept, Note(title: "o", body: "b")])
    let decoded = try! NoteArchive.decode(archive)
    expect("keep archive: round-trips", String(decoded[0].keepOnDeck), "true")
    expect("keep archive: ordinary stays off", String(decoded[1].keepOnDeck), "false")
    expectTrue("keep archive: an ordinary note writes no key",
               String(data: archive, encoding: .utf8)!.components(separatedBy: "keepOnDeck").count == 2)

    // A database from before it existed.
    let legacyURL = scratchDirectory().appendingPathComponent("legacy-keep.sqlite")
    let id: UUID = {
        let s = reopened(legacyURL, key: key)
        let id = try! s.create(title: "old", body: "b").id
        s.waitUntilSaved()
        return id
    }()
    do {
        let db = try! SQLiteDatabase(path: legacyURL.path)
        try! db.execute("ALTER TABLE notes DROP COLUMN edited_at; ALTER TABLE notes DROP COLUMN keep_on_deck; ALTER TABLE notes DROP COLUMN pinned_at; ALTER TABLE notes DROP COLUMN last_opened_day; ALTER TABLE notes DROP COLUMN auto_archived_day; PRAGMA user_version = 4;")
    }
    let migrated = reopened(legacyURL, key: key)
    expect("keep migration: the note survives, not kept", String(migrated.note(id: id)?.keepOnDeck ?? true), "false")
}

@MainActor
func runPinStoreTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("pins.sqlite")
    var store: NoteStore? = reopened(database, key: key)
    store!.now = { Date(timeIntervalSince1970: 1_790_000_000) }   // a frozen clock: pins still come out in order
    let notes = (0..<7).map { try! store!.create(title: "n\($0)", body: "x") }

    expect("pin: off by default", String(notes[0].isPinned), "false")
    expect("pin: the first goes through", String(describing: try! store!.setPinned(true, id: notes[0].id)), "done")
    expect("pin: and turns Keep on Deck on", String(store!.note(id: notes[0].id)?.keepOnDeck ?? false), "true")
    for index in 1..<5 { try! store!.setPinned(true, id: notes[index].id) }
    expect("pin: five are pinned", String(store!.pinnedNotes.count), "5")
    let order = store!.pinnedNotes.sorted { $0.pinnedAt! < $1.pinnedAt! }.map(\.title)
    expect("pin: in the order they were pinned, even on a frozen clock", order.joined(separator: ","), "n0,n1,n2,n3,n4")

    expect("pin: the sixth is refused", String(describing: try! store!.setPinned(true, id: notes[5].id)), "limitReached")
    expect("pin: and nothing changes", String(store!.note(id: notes[5].id)?.isPinned ?? true), "false")
    expect("pin: nor does its Keep on Deck", String(store!.note(id: notes[5].id)?.keepOnDeck ?? true), "false")
    expect("pin: pinning a pinned note is fine", String(describing: try! store!.setPinned(true, id: notes[0].id)), "done")

    try! store!.setPinned(false, id: notes[2].id)
    expect("pin: unpinning frees a place", String(store!.pinnedNotes.count), "4")
    expect("pin: and leaves Keep on Deck on", String(store!.note(id: notes[2].id)?.keepOnDeck ?? false), "true")
    expect("pin: now the sixth fits", String(describing: try! store!.setPinned(true, id: notes[5].id)), "done")
    let latest = store!.note(id: notes[5].id)!.pinnedAt!
    expectTrue("pin: and it is the last of them", store!.pinnedNotes.allSatisfy { $0.id == notes[5].id || $0.pinnedAt! < latest })

    try! store!.archive(id: notes[3].id)
    expect("pin: archiving a pinned note unpins it", String(store!.note(id: notes[3].id)?.isPinned ?? true), "false")
    expect("pin: an archived note cannot be pinned", String(describing: try! store!.setPinned(true, id: notes[3].id)), "notOnDeck")
    store!.waitUntilSaved()
    store = nil

    let again = reopened(database, key: key)
    expect("pin: remembered across launches", String(again.pinnedNotes.count), "4")
    expect("pin: with its moment", String(again.note(id: notes[0].id)?.pinnedAt != nil), "true")

    // The .hmnote file.
    let when = Date(timeIntervalSince1970: 1_790_000_123.456)
    let pinned = Note(title: "t", body: "b", pinnedAt: when)
    let text = HMNoteFile(note: pinned).serialized()
    expectTrue("pin file: a header line", text.contains("\npinned: "))
    let parsed = HMNoteFile.parse(text)
    expect("pin file: round-trips to the millisecond",
           String(Int(((parsed?.pinnedAt ?? .distantPast).timeIntervalSince1970 * 1000).rounded())), "1790000123456")
    expect("pin file: reaches the note", String(parsed?.note.isPinned ?? false), "true")
    expectTrue("pin file: an ordinary note writes none", !HMNoteFile(note: Note(title: "o", body: "b")).serialized().contains("pinned:"))

    // The archive package.
    let archive = try! NoteArchive.encode(notes: [pinned, Note(title: "o", body: "b")])
    let decoded = try! NoteArchive.decode(archive)
    expect("pin archive: round-trips", String(decoded[0].isPinned), "true")
    expect("pin archive: ordinary stays unpinned", String(decoded[1].isPinned), "false")

    // A database from before it existed.
    let legacyURL = scratchDirectory().appendingPathComponent("legacy-pin.sqlite")
    let id: UUID = {
        let s = reopened(legacyURL, key: key)
        let id = try! s.create(title: "old", body: "b").id
        s.waitUntilSaved()
        return id
    }()
    do {
        let db = try! SQLiteDatabase(path: legacyURL.path)
        try! db.execute("ALTER TABLE notes DROP COLUMN edited_at; ALTER TABLE notes DROP COLUMN pinned_at; ALTER TABLE notes DROP COLUMN last_opened_day; ALTER TABLE notes DROP COLUMN auto_archived_day; PRAGMA user_version = 5;")
    }
    expect("pin migration: the note survives, unpinned", String(reopened(legacyURL, key: key).note(id: id)?.isPinned ?? true), "false")
}

@MainActor
func runArchiveSettingTests() {
    let suite = "keepnote-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    expect("setting: fourteen days until chosen", String(settings.archiveAfterDays), "14")
    settings.archiveAfterDays = 7
    expect("setting: seven", String(AppSettings(defaults: defaults).archiveAfterDays), "7")
    settings.archiveAfterDays = 30
    expect("setting: thirty, remembered", String(AppSettings(defaults: defaults).archiveAfterDays), "30")
    settings.archiveAfterDays = 21
    expect("setting: a value that is not a choice falls back", String(settings.archiveAfterDays), "14")
    defaults.set(5, forKey: "archiveAfterDays")
    expect("setting: and so does one left in the preferences", String(AppSettings(defaults: defaults).archiveAfterDays), "14")
}

@MainActor
func runOpenedDayStoreTests() {
    let key = SymmetricKey(size: .bits256)
    let database = scratchDirectory().appendingPathComponent("opened.sqlite")
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    var clock = base
    func day(_ date: Date) -> String { DailyDay(date).string }
    func daysLater(_ days: Double) -> Date { base.addingTimeInterval(days * 86_400) }

    var store: NoteStore? = reopened(database, key: key)
    store!.now = { clock }
    let first = clock
    let note = try! store!.create(title: "n", body: "b")
    expect("opened: a new note starts today", store!.note(id: note.id)?.lastOpenedDay?.string, day(first))

    clock = daysLater(3)
    let edited = store!.note(id: note.id)!.updatedAt
    try! store!.markOpened(id: note.id)
    expect("opened: opening it moves its day", store!.note(id: note.id)?.lastOpenedDay?.string, day(clock))
    expectTrue("opened: and is not an edit", store!.note(id: note.id)?.updatedAt == edited)

    var writes = 0
    let watcher = store!.changes.sink { _ in writes += 1 }
    try! store!.markOpened(id: note.id)
    try! store!.markOpened(id: note.id)
    expect("opened: the same day is written once, not again", String(writes), "0")
    clock = clock.addingTimeInterval(3600)
    if day(clock) == day(daysLater(3)) {
        try! store!.markOpened(id: note.id)
        expect("opened: nor an hour later", String(writes), "0")
    }
    clock = daysLater(4)
    try! store!.markOpened(id: note.id)
    expect("opened: the next day is written", String(writes), "1")
    watcher.cancel()
    store!.waitUntilSaved()
    store = nil

    let again = reopened(database, key: key)
    expect("opened: remembered across launches", again.note(id: note.id)?.lastOpenedDay?.string, day(daysLater(4)))
    // (A date through the database can differ in its last bit, hence the tolerance.)
    expectTrue("opened: with the edit date as it was",
               abs((again.note(id: note.id)?.updatedAt ?? .distantPast).timeIntervalSince(edited)) < 0.001)

    // Archiving and bringing back starts the time again.
    again.now = { daysLater(9) }
    try! again.archive(id: note.id)
    expect("opened: archiving does not touch it", again.note(id: note.id)?.lastOpenedDay?.string, day(daysLater(4)))
    try! again.unarchive(id: note.id)
    expect("opened: bringing it back starts the time again", again.note(id: note.id)?.lastOpenedDay?.string, day(daysLater(9)))

    // The .hmnote file and the archive package.
    let opened = Note(title: "t", body: "b", lastOpenedDay: DailyDay(string: "2026-09-30"))
    let text = HMNoteFile(note: opened).serialized()
    expectTrue("opened file: a header line", text.contains("\nopened: 2026-09-30\n"))
    expect("opened file: round-trips", HMNoteFile.parse(text)?.lastOpenedDay?.string, "2026-09-30")
    expect("opened file: reaches the note", HMNoteFile.parse(text)?.note.lastOpenedDay?.string, "2026-09-30")
    expectTrue("opened file: none, none written", !HMNoteFile(note: Note(title: "o", body: "b")).serialized().contains("opened:"))
    expect("opened file: a day that is not a day is ignored",
           HMNoteFile.parse(text.replacingOccurrences(of: "2026-09-30", with: "soon"))?.lastOpenedDay?.string, nil)
    let archive = try! NoteArchive.encode(notes: [opened, Note(title: "o", body: "b")])
    let decoded = try! NoteArchive.decode(archive)
    expect("opened archive: round-trips", decoded[0].lastOpenedDay?.string, "2026-09-30")
    expect("opened archive: none stays none", decoded[1].lastOpenedDay?.string, nil)
    expectTrue("opened archive: none, no key", String(data: archive, encoding: .utf8)!.components(separatedBy: "lastOpenedDay").count == 2)

    // A database from before it existed: every note starts counting the day
    // this version first runs, and that is saved, so it is the same next time.
    let legacyURL = scratchDirectory().appendingPathComponent("legacy-opened.sqlite")
    let ids: [UUID] = {
        let s = reopened(legacyURL, key: key)
        let a = try! s.create(title: "a", body: "b").id
        let b = try! s.create(title: "b", body: "b", tags: ["daily"]).id
        s.waitUntilSaved()
        return [a, b]
    }()
    let before: [UUID: Date] = {
        let s = reopened(legacyURL, key: key)
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, s.note(id: $0)!.updatedAt) })
    }()
    do {
        let db = try! SQLiteDatabase(path: legacyURL.path)
        try! db.execute("ALTER TABLE notes DROP COLUMN edited_at; ALTER TABLE notes DROP COLUMN last_opened_day; ALTER TABLE notes DROP COLUMN auto_archived_day; PRAGMA user_version = 6;")
    }
    let firstRun = Date(timeIntervalSince1970: 1_800_000_000)
    let migrated = try! NoteStore(databaseURL: legacyURL, cipher: BodyCipher(key: key), now: { firstRun })
    migrated.waitUntilSaved()
    expect("opened migration: every note starts today", ids.map { migrated.note(id: $0)?.lastOpenedDay?.string ?? "-" }.joined(separator: ","),
           [day(firstRun), day(firstRun)].joined(separator: ","))
    expectTrue("opened migration: no edit dates move", ids.allSatisfy { migrated.note(id: $0)?.updatedAt == before[$0] })
    let later = Date(timeIntervalSince1970: 1_800_000_000 + 20 * 86_400)
    let secondRun = try! NoteStore(databaseURL: legacyURL, cipher: BodyCipher(key: key), now: { later })
    expect("opened migration: and it is saved, so a later launch does not reset it", secondRun.note(id: ids[0])?.lastOpenedDay?.string, day(firstRun))

    // Two Macs: the later opening wins, whichever file arrives last.
    let a = try! NoteStore(databaseURL: scratchDirectory().appendingPathComponent("a.sqlite"), cipher: BodyCipher(key: key), now: { firstRun })
    let shared = try! a.create(title: "shared", body: "b")
    var older = a.note(id: shared.id)!
    older.lastOpenedDay = DailyDay(string: "2026-10-01")
    var newer = older
    newer.lastOpenedDay = DailyDay(string: "2026-10-06")
    try! a.update(id: shared.id, touchTimestamp: false) { $0.lastOpenedDay = DailyDay(string: "2026-10-03") }
    let unchanged = a.note(id: shared.id)!.updatedAt
    _ = try! a.applyIncoming([newer])
    expect("opened sync: a copy no newer still brings a later day", a.note(id: shared.id)?.lastOpenedDay?.string, "2026-10-06")
    expectTrue("opened sync: without changing the edit date", a.note(id: shared.id)?.updatedAt == unchanged)
    _ = try! a.applyIncoming([older])
    expect("opened sync: an earlier day never moves it back", a.note(id: shared.id)?.lastOpenedDay?.string, "2026-10-06")
    var edit = a.note(id: shared.id)!
    edit.updatedAt = unchanged.addingTimeInterval(60)
    edit.title = "edited elsewhere"
    edit.lastOpenedDay = DailyDay(string: "2026-10-02")
    _ = try! a.applyIncoming([edit])
    expect("opened sync: a newer edit takes its text", a.note(id: shared.id)?.title, "edited elsewhere")
    expect("opened sync: but not an older opening day", a.note(id: shared.id)?.lastOpenedDay?.string, "2026-10-06")
    var oldWriter = edit
    oldWriter.updatedAt = unchanged.addingTimeInterval(120)
    oldWriter.lastOpenedDay = nil
    _ = try! a.applyIncoming([oldWriter])
    expect("opened sync: a file from an older KeepNote has none and says nothing", a.note(id: shared.id)?.lastOpenedDay?.string, "2026-10-06")
}

@MainActor
func runTimeRuleStoreTests() {
    let key = SymmetricKey(size: .bits256)
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    func daysLater(_ days: Int) -> Date { base.addingTimeInterval(Double(days) * 86_400) }
    func day(_ days: Int) -> String { DailyDay(daysLater(days)).string }
    let url = scratchDirectory().appendingPathComponent("rule.sqlite")
    var clock = base
    var store: NoteStore? = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: key), now: { clock })

    let plain = try! store!.create(title: "plain", body: "x")
    let kept = try! store!.create(title: "kept", body: "x")
    let pinned = try! store!.create(title: "pinned", body: "x")
    let open = try! store!.create(title: "open", body: "x")
    let daily = try! store!.create(title: "daily", body: "x", tags: ["daily"])
    let doomed = try! store!.create(title: "deleted", body: "x")
    try! store!.setKeepOnDeck(true, id: kept.id)
    try! store!.setPinned(true, id: pinned.id)
    try! store!.delete(id: doomed.id)
    let edits = Dictionary(uniqueKeysWithValues: store!.notes.map { ($0.id, $0.updatedAt) })
    let count = store!.notes.count + store!.pendingDeletions.count

    clock = daysLater(13)
    expect("time rule: nothing before its day", String(try! store!.archiveStale(days: 14).count), "0")
    clock = daysLater(14)
    let archivedNow = try! store!.archiveStale(open: [open.id], days: 14)
    expect("time rule: on its day, the plain note goes", archivedNow.map { store!.note(id: $0)?.title ?? "?" }.joined(separator: ","), "plain")
    expect("time rule: it is archived", store!.note(id: plain.id)?.state.rawValue, "archived")
    for (name, note) in [("kept", kept), ("pinned", pinned), ("open", open), ("daily", daily)] {
        expect("time rule: \(name) stays", store!.note(id: note.id)?.state.rawValue, "active")
    }
    expect("time rule: nothing is deleted", String(store!.notes.count + store!.pendingDeletions.count), String(count))
    expect("time rule: and the edit date stays", String(store!.note(id: plain.id)?.updatedAt == edits[plain.id]), "true")
    expect("time rule: twice, nothing more", String(try! store!.archiveStale(open: [open.id], days: 14).count), "0")

    // The window closes: its day is today, so it is safe for the whole time again.
    try! store!.markOpened(id: open.id)
    expect("time rule: a note that was open is not archived at once on closing", String(try! store!.archiveStale(days: 14).count), "0")
    clock = daysLater(28)
    expect("time rule: ...until its own time is up", String(try! store!.archiveStale(days: 14).count), "1")
    expect("time rule: kept and pinned still", [store!.note(id: kept.id)?.state.rawValue, store!.note(id: pinned.id)?.state.rawValue].compactMap { $0 }.joined(separator: ","), "active,active")
    expect("time rule: the daily follows its own rule, not this one", store!.note(id: daily.id)?.state.rawValue, "active")

    // Unpinned and un-kept notes are exposed again from then on.
    try! store!.setPinned(false, id: pinned.id)
    expect("time rule: unpinning leaves it kept", String(try! store!.archiveStale(days: 14).count), "0")
    try! store!.setKeepOnDeck(false, id: kept.id)
    try! store!.setKeepOnDeck(false, id: pinned.id)
    expect("time rule: both are the rule's now", String(try! store!.archiveStale(days: 14).count), "2")

    // A launch later, the same notes give the same answer.
    store!.waitUntilSaved()
    store = nil
    var again: NoteStore? = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: key), now: { clock })
    expect("time rule: the next launch has nothing to do", String(try! again!.archiveStale(days: 14).count), "0")
    expect("time rule: the archived ones stayed archived", String(again!.notes.filter { $0.state == .archived }.count), "4")
    again = nil

    // A shorter setting archives more, a longer one less, from the same notes.
    let a = try! NoteStore(databaseURL: scratchDirectory().appendingPathComponent("a.sqlite"), cipher: BodyCipher(key: key), now: { base })
    for _ in 0..<6 { _ = try! a.create(title: "n", body: "b") }
    var later = base.addingTimeInterval(10 * 86_400)
    a.now = { later }
    expect("time rule: ten days idle, thirty days: none", String(try! a.archiveStale(days: 30).count), "0")
    expect("time rule: ten days idle, fourteen days: none", String(try! a.archiveStale(days: 14).count), "0")
    expect("time rule: ten days idle, seven days: all", String(try! a.archiveStale(days: 7).count), "6")
    later = base

    // Two Macs, same notes: the same notes archived.
    let first = try! NoteStore(databaseURL: scratchDirectory().appendingPathComponent("m1.sqlite"), cipher: BodyCipher(key: key), now: { base })
    let second = try! NoteStore(databaseURL: scratchDirectory().appendingPathComponent("m2.sqlite"), cipher: BodyCipher(key: key), now: { base })
    let made = (0..<8).map { try! first.create(title: "n\($0)", body: "b") }
    _ = try! second.applyIncoming(made)
    try! first.update(id: made[0].id, touchTimestamp: false) { $0.lastOpenedDay = DailyDay(daysLater(10)) }
    _ = try! second.applyIncoming([first.note(id: made[0].id)!])
    for store in [first, second] { store.now = { daysLater(14) } }
    let planFirst = try! first.archiveStale(days: 14)
    let planSecond = try! second.archiveStale(days: 14)
    expectTrue("time rule: two Macs archive the same notes", planFirst == planSecond)
    expect("time rule: all but the one opened later", String(planFirst.count), "7")
}

@MainActor
func runAutoArchivedMarkTests() {
    let key = SymmetricKey(size: .bits256)
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    var clock = base
    let url = scratchDirectory().appendingPathComponent("marked.sqlite")
    var store: NoteStore? = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: key), now: { clock })
    let byRule = try! store!.create(title: "by rule", body: "x")
    let byHand = try! store!.create(title: "by hand", body: "x")
    let live = try! store!.create(title: "live", body: "x")

    try! store!.archive(id: byHand.id)
    expect("auto mark: a note archived by hand has none", store!.note(id: byHand.id)?.autoArchivedDay?.string, nil)
    expect("auto mark: a note on the deck has none", store!.note(id: live.id)?.autoArchivedDay?.string, nil)

    clock = base.addingTimeInterval(20 * 86_400)
    try! store!.markOpened(id: live.id)
    try! store!.markOpened(id: byHand.id)
    _ = try! store!.archiveStale(days: 14)
    expect("auto mark: archived by the rule, with the day", store!.note(id: byRule.id)?.autoArchivedDay?.string, DailyDay(clock).string)
    expect("auto mark: and it is archived", store!.note(id: byRule.id)?.state.rawValue, "archived")
    expect("auto mark: a note that was not touched has none", store!.note(id: live.id)?.autoArchivedDay?.string, nil)
    expectTrue("auto mark: it says so in the Archive", MainActor.assumeIsolated { DeckStatus.archivedLine(for: store!.note(id: byRule.id)!) }?.hasPrefix("Archived automatically \u{00B7} ") == true)
    expectTrue("auto mark: and not for one archived by hand", MainActor.assumeIsolated { DeckStatus.archivedLine(for: store!.note(id: byHand.id)!) } == nil)
    expect("auto mark: it stays in the common Archive", String(store!.archivedNotes.map(\.title).sorted().joined(separator: ",") == "by hand,by rule"), "true")
    store!.waitUntilSaved()
    store = nil

    let again = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: key), now: { clock })
    expect("auto mark: remembered across launches", again.note(id: byRule.id)?.autoArchivedDay?.string, DailyDay(clock).string)
    try! again.unarchive(id: byRule.id)
    expect("auto mark: bringing it back clears it", again.note(id: byRule.id)?.autoArchivedDay?.string, nil)
    expect("auto mark: and starts its time again", again.note(id: byRule.id)?.lastOpenedDay?.string, DailyDay(clock).string)
    try! again.archive(id: byRule.id)
    expect("auto mark: archived by hand afterwards it stays unmarked", again.note(id: byRule.id)?.autoArchivedDay?.string, nil)

    // The file and the archive package.
    let marked = Note(title: "t", body: "b", state: .archived, autoArchivedDay: DailyDay(string: "2026-10-05"))
    let text = HMNoteFile(note: marked).serialized()
    expectTrue("auto mark file: a header line", text.contains("\nauto-archived: 2026-10-05\n"))
    expect("auto mark file: round-trips", HMNoteFile.parse(text)?.note.autoArchivedDay?.string, "2026-10-05")
    expectTrue("auto mark file: none, none written", !HMNoteFile(note: Note(title: "o", body: "b")).serialized().contains("auto-archived"))
    let archive = try! NoteArchive.encode(notes: [marked, Note(title: "o", body: "b")])
    let decoded = try! NoteArchive.decode(archive)
    expect("auto mark archive: round-trips", decoded[0].autoArchivedDay?.string, "2026-10-05")
    expect("auto mark archive: and stays archived", decoded[0].state.rawValue, "archived")
    expect("auto mark archive: none stays none", decoded[1].autoArchivedDay?.string, nil)

    // A database from before it existed.
    let legacyURL = scratchDirectory().appendingPathComponent("legacy-auto.sqlite")
    let id: UUID = {
        let s = try! NoteStore(databaseURL: legacyURL, cipher: BodyCipher(key: key), now: { clock })
        let id = try! s.create(title: "old", body: "b").id
        try! s.archive(id: id)
        s.waitUntilSaved()
        return id
    }()
    do {
        let db = try! SQLiteDatabase(path: legacyURL.path)
        try! db.execute("ALTER TABLE notes DROP COLUMN edited_at; ALTER TABLE notes DROP COLUMN auto_archived_day; PRAGMA user_version = 7;")
    }
    let migrated = try! NoteStore(databaseURL: legacyURL, cipher: BodyCipher(key: key), now: { clock })
    expect("auto mark migration: an archived note stays archived, unmarked",
           (migrated.note(id: id)?.state.rawValue ?? "?") + "/" + (migrated.note(id: id)?.autoArchivedDay?.string ?? "none"), "archived/none")
}
