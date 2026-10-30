import AppKit
import CryptoKit

// MARK: - Groups in the database

@MainActor
func runGroupStoreTests() {
    let key = SymmetricKey(size: .bits256)

    // MARK: A database from before groups

    do {
        let database = scratchDirectory().appendingPathComponent("old.sqlite")
        var store: NoteStore? = reopened(database, key: key)
        let kept = try! store!.create(title: "kept", body: "from before", tags: ["x"]).id
        let second = try! store!.create(title: "second").id
        store!.waitUntilSaved()
        store = nil

        // Put the file back as version 12 had it: no group column, no groups table.
        do {
            let db = try! SQLiteDatabase(path: database.path)
            try! db.execute("DROP TABLE note_groups;")
            try! db.execute("ALTER TABLE notes DROP COLUMN group_id;")
            db.userVersion = 12
        }

        let migrated = reopened(database, key: key)
        migrated.waitUntilSaved()
        expect("migrate: the notes are all there", String(migrated.notes.count), "2")
        expect("migrate: unchanged", migrated.note(id: kept)?.body, "from before")
        expect("migrate: and its tags", migrated.note(id: kept)?.tags.joined(), "x")
        expectTrue("migrate: in no group", migrated.notes.allSatisfy { $0.groupID == nil })
        expectTrue("migrate: with no groups", migrated.groups.isEmpty)
        expect("migrate: the database is at the new version",
               String(try! SQLiteDatabase(path: database.path).userVersion), String(NoteSchema.currentVersion))
        let backups = Backups.list(in: Backups.directory(for: database))
        expectTrue("migrate: a backup was made first", backups.contains { $0.kind == .migration })
        if let backup = backups.first(where: { $0.kind == .migration }) {
            let copy = try! SQLiteDatabase(readOnlyPath: backup.url.path)
            expect("migrate: the backup is the old file, version 12", String(copy.userVersion), "12")
            expect("migrate: and holds both notes", String(try! copy.scalarInt("SELECT count(*) FROM notes;")), "2")
        }
        // It works afterwards: a group, a note in it, a relaunch.
        let group = migrated.createGroup(name: "After")!
        try! migrated.setGroup(group.id, for: [second])
        migrated.waitUntilSaved()
        let again = reopened(database, key: key)
        expectTrue("migrate: a group made after is kept", again.groups.map(\.name) == ["After"])
        expectTrue("migrate: and its note", again.note(id: second)?.groupID == group.id)
        // Opening a migrated database again does not migrate it again.
        let backupCount = Backups.list(in: Backups.directory(for: database)).count
        _ = reopened(database, key: key)
        expect("migrate: no second backup for a database already up to date",
               String(Backups.list(in: Backups.directory(for: database)).count), String(backupCount))
    }

    // MARK: Making, naming, colouring, ordering

    let database = scratchDirectory().appendingPathComponent("groups.sqlite")
    var store: NoteStore! = reopened(database, key: key)
    expectTrue("groups: none at first", store.groups.isEmpty)
    let work = store.createGroup(name: "  Work ")!
    let home = store.createGroup(name: "Home", color: .teal)!
    let third = store.createGroup(name: "Ideas")!
    expect("groups: a name is cleaned", work.name, "Work")
    expectTrue("groups: nothing is not a name", store.createGroup(name: "   ") == nil)
    expect("groups: in the order they were made", store.groups.map(\.name).joined(separator: ","), "Work,Home,Ideas")
    expectTrue("groups: a colour chosen is kept", home.color == .teal)
    expectTrue("groups: one not chosen walks the palette", third.color == home.color.next)
    expect("groups: places are dense", store.groups.map(\.order).map(String.init).joined(separator: ","), "0,1,2")

    expectTrue("rename: done", store.renameGroup(id: work.id, to: "Office"))
    expectTrue("rename: to what it is is nothing", !store.renameGroup(id: work.id, to: "Office"))
    expectTrue("rename: to nothing is refused", !store.renameGroup(id: work.id, to: "  "))
    expect("rename: kept", store.group(id: work.id)?.name, "Office")
    store.setGroupColor(.pink, id: work.id)
    expectTrue("colour: changed", store.group(id: work.id)?.color == .pink)
    expectTrue("rename: the change is later than the making",
               store.group(id: work.id)!.updatedAt > work.updatedAt)

    store.moveGroup(id: third.id, to: 0)
    expect("reorder: moved to the front", store.groups.map(\.name).joined(separator: ","), "Ideas,Office,Home")
    store.reorderGroups(ids: [home.id, third.id, work.id])
    expect("reorder: by a list of ids", store.groups.map(\.name).joined(separator: ","), "Home,Ideas,Office")
    expect("reorder: places stay dense", store.groups.map(\.order).map(String.init).joined(separator: ","), "0,1,2")

    // MARK: Notes in groups

    let n1 = try! store.create(title: "one").id
    let n2 = try! store.create(title: "two").id
    let n3 = try! store.create(title: "three").id
    expect("move: two notes into a group", String(try! store.setGroup(work.id, for: [n1, n2])), "2")
    expect("move: the same again moves none", String(try! store.setGroup(work.id, for: [n1, n2])), "0")
    expect("move: into a group that does not exist moves none", String(try! store.setGroup(UUID(), for: [n3])), "0")
    expectTrue("move: that note is in none", store.note(id: n3)?.groupID == nil)
    expect("move: the group holds them", store.notes(inGroup: work.id).map(\.title).joined(separator: ","), "one,two")
    let editedBefore = store.note(id: n1)!.editedAt
    let updatedBefore = store.note(id: n1)!.updatedAt
    try! store.setGroup(home.id, for: [n1])
    expectTrue("move: it is a change for sync", store.note(id: n1)!.updatedAt > updatedBefore)
    expectTrue("move: but not an edit of the text", store.note(id: n1)!.editedAt == editedBefore)
    try! store.setGroup(nil, for: [n1])
    expectTrue("move: out of every group", store.note(id: n1)?.groupID == nil)
    expectTrue("new note: born in a group", try! store.create(title: "born", group: work.id).groupID == work.id)
    expectTrue("new note: not in a group that does not exist", try! store.create(title: "orphan", group: UUID()).groupID == nil)

    // Archived notes keep their group, and come back to it.
    try! store.archive(id: n2)
    expectTrue("archive: keeps the group", store.note(id: n2)?.groupID == work.id)
    try! store.unarchive(id: n2)
    expectTrue("archive: and it is still there when it comes back", store.note(id: n2)?.groupID == work.id)
    let lastInStack = store.activeNotes.map(\.sortIndex).max()
    expectTrue("archive: and it comes back at the end of the stack, so the end of its group",
               store.note(id: n2)?.sortIndex == lastInStack && store.activeNotes.last?.id == n2)

    // A daily is in the Daily group of the deck, never in one of these.
    let daily = try! store.create(title: "Daily", tags: [DailyNotes.tag], group: work.id)
    expectTrue("daily: born in no group", daily.groupID == nil)
    expect("daily: moving it moves nothing", String(try! store.setGroup(work.id, for: [daily.id])), "0")
    expectTrue("daily: still in none", store.note(id: daily.id)?.groupID == nil)
    try! store.setGroup(home.id, for: [n3])
    try! store.setTags([DailyNotes.tag], id: n3)
    expectTrue("daily: a note given the tag leaves its group", store.note(id: n3)?.groupID == nil)

    // MARK: It lasts

    store.waitUntilSaved()
    store = nil
    let reopenedStore = reopened(database, key: key)
    expect("lasts: the groups, in order", reopenedStore.groups.map(\.name).joined(separator: ","), "Home,Ideas,Office")
    expectTrue("lasts: the colours", reopenedStore.group(id: work.id)?.color == .pink && reopenedStore.group(id: home.id)?.color == .teal)
    expectTrue("lasts: a note's group", reopenedStore.note(id: n2)?.groupID == work.id)
    expectTrue("lasts: and its order among the notes", reopenedStore.notes(inGroup: work.id).map(\.title).prefix(2).joined(separator: ",") == "born,two")

    // MARK: Deleting a group never deletes a note

    let before = reopenedStore.notes.count
    let inWork = reopenedStore.notes(inGroup: work.id).map(\.id)
    expectTrue("delete: the group has notes", inWork.count >= 2)
    try! reopenedStore.deleteGroup(id: work.id)
    expectTrue("delete: the group is gone", reopenedStore.group(id: work.id) == nil)
    expect("delete: every note is still there", String(reopenedStore.notes.count), String(before))
    expectTrue("delete: and in no group", inWork.allSatisfy { reopenedStore.note(id: $0)?.groupID == nil })
    expect("delete: the others are as they were", reopenedStore.groups.map(\.name).joined(separator: ","), "Home,Ideas")
    expectTrue("delete: the record stays, deleted, for sync", reopenedStore.groupRecord(id: work.id)?.deletedAt != nil)
    expectTrue("delete: no note was deleted", reopenedStore.pendingDeletions.isEmpty)
    reopenedStore.waitUntilSaved()
    let last = reopened(database, key: key)
    expectTrue("delete: still gone after a relaunch", last.group(id: work.id) == nil)
    expectTrue("delete: and still no note lost", last.notes.count == before)
    expectTrue("delete: and still no group on them", inWork.allSatisfy { last.note(id: $0)?.groupID == nil })
    expectTrue("delete: a note cannot be moved into it", (try? last.setGroup(work.id, for: [inWork[0]])) == 0)

    // A note that names a group this Mac does not have is in none.
    let strayed = Note(title: "stray", body: "x", groupID: UUID())
    try! last.applyIncoming(strayed)
    expectTrue("stray: it is kept", last.note(id: strayed.id) != nil)
    expectTrue("stray: and counted as in no group",
               GroupLibrary.counts(last.notes, groups: last.groups).ungrouped >= 1
               && GroupLibrary.effectiveGroup(of: last.note(id: strayed.id)!, among: last.groups) == nil)
}

// MARK: - Groups in the sync folder

@MainActor
func runGroupSyncTests() {
    let key = SymmetricKey(size: .bits256)
    let folder = scratchDirectory().appendingPathComponent("Sync", isDirectory: true)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // MARK: The files

    let when = Date(timeIntervalSince1970: 1_790_000_000.123)
    let group = NoteGroup(name: "Work: \"big\" ones\nand more\\", color: .indigo, order: 3, createdAt: when, updatedAt: when.addingTimeInterval(60))
    let parsed = GroupFile.parse(GroupFile.serialized(GroupRecord(group: group, deletedAt: nil)))
    expectTrue("file: the id round-trips", parsed?.group.id == group.id)
    expect("file: the name, colons, quotes, newlines and all", parsed?.group.name, "Work: \"big\" ones and more\\")
    expectTrue("file: the colour", parsed?.group.color == .indigo)
    expect("file: the place", parsed.map { String($0.group.order) }, "3")
    expectTrue("file: the dates", parsed.map { abs($0.group.updatedAt.timeIntervalSince(group.updatedAt)) < 0.001
        && abs($0.group.createdAt.timeIntervalSince(group.createdAt)) < 0.001 } ?? false)
    expectTrue("file: not deleted", parsed?.deletedAt == nil)
    let gone = GroupFile.parse(GroupFile.serialized(GroupRecord(group: group, deletedAt: when.addingTimeInterval(120))))
    expectTrue("file: a deletion round-trips", gone.map { abs($0.deletedAt!.timeIntervalSince(when.addingTimeInterval(120))) < 0.001 } ?? false)
    expectTrue("file: a note file is not a group", GroupFile.parse(HMNoteFile(note: Note(title: "t", body: "b")).serialized()) == nil)
    expectTrue("file: a group file is not a note", HMNoteFile.parse(GroupFile.serialized(GroupRecord(group: group, deletedAt: nil))) == nil)
    expectTrue("file: its extension is its own", GroupFile.fileName(for: group.id).hasSuffix(".hmgroup"))
    expectTrue("file: a colour from a newer build is the default",
               GroupFile.parse(GroupFile.serialized(GroupRecord(group: group, deletedAt: nil))
                   .replacingOccurrences(of: "color: 9", with: "color: 77"))?.group.color == .default)

    // A note's file says its group, and an old file with no such line is valid.
    let inGroup = HMNoteFile(note: Note(title: "n", body: "b", groupID: group.id))
    expect("note file: says the group", inGroup.serialized().components(separatedBy: "\n").first { $0.hasPrefix("group:") }, "group: \(group.id.uuidString)")
    expectTrue("note file: and reads it back", HMNoteFile.parse(inGroup.serialized())?.groupID == group.id)
    expectTrue("note file: no group, no line", !HMNoteFile(note: Note(title: "n", body: "b")).serialized().contains("group:"))
    let old = "--- keepnote ---\nschema: 1\nid: \(UUID().uuidString)\ntitle: old\ncolor: 1\nstate: active\ntags: \ncreated: 2026-10-01T10:00:00.000Z\nupdated: 2026-10-01T10:00:00.000Z\n---\n\nbody"
    expectTrue("note file: one from before groups is valid", HMNoteFile.parse(old) != nil && HMNoteFile.parse(old)?.groupID == nil)

    // MARK: Between two folders' worth of Macs

    let first = reopened(scratchDirectory().appendingPathComponent("a.sqlite"), key: key)
    let sync = FolderSyncService(store: first, folder: folder)
    spin(0.3)
    sync.waitUntilWritten()
    let work = first.createGroup(name: "Work", color: .red)!
    let home = first.createGroup(name: "Home", color: .green)!
    let inWork = try! first.create(title: "in work", body: "w", group: work.id)
    let loose = try! first.create(title: "loose", body: "l")
    spin(0.3)
    sync.waitUntilWritten()
    expectTrue("sync: a group reaches the folder", FileManager.default.fileExists(atPath: folder.appendingPathComponent(GroupFile.fileName(for: work.id)).path))
    expectTrue("sync: and a note says its group", noteFile(in: folder, id: inWork.id)?.groupID == work.id)
    expectTrue("sync: a loose note says none", noteFile(in: folder, id: loose.id)?.groupID == nil)

    let second = reopened(scratchDirectory().appendingPathComponent("b.sqlite"), key: key)
    let other = FolderSyncService(store: second, folder: folder)
    spin(0.6)
    other.waitUntilWritten()
    spin(0.2)
    expect("sync: another Mac takes the groups, in order", second.groups.map(\.name).joined(separator: ","), "Work,Home")
    expectTrue("sync: with their colours", second.group(id: work.id)?.color == .red && second.group(id: home.id)?.color == .green)
    expectTrue("sync: and the notes in them", second.note(id: inWork.id)?.groupID == work.id)
    expectTrue("sync: and the loose one loose", second.note(id: loose.id)?.groupID == nil)
    expect("sync: the group holds the note there", second.notes(inGroup: work.id).map(\.title).joined(), "in work")

    // The other Mac renames, recolours and reorders; the first follows.
    second.renameGroup(id: work.id, to: "Office")
    second.setGroupColor(.orange, id: work.id)
    second.moveGroup(id: home.id, to: 0)
    spin(0.3)
    other.waitUntilWritten()
    sync.reconfigure()
    spin(0.6)
    sync.waitUntilWritten()
    spin(0.2)
    expect("sync: a rename arrives", first.group(id: work.id)?.name, "Office")
    expectTrue("sync: and a colour", first.group(id: work.id)?.color == .orange)
    expect("sync: and the new order", first.groups.map(\.name).joined(separator: ","), "Home,Office")

    // It moves a note to another group, and the first follows.
    try! second.setGroup(home.id, for: [inWork.id])
    spin(0.3)
    other.waitUntilWritten()
    sync.reconfigure()
    spin(0.6)
    sync.waitUntilWritten()
    spin(0.2)
    expectTrue("sync: a note moved to another group arrives there", first.note(id: inWork.id)?.groupID == home.id)

    // A group made on both Macs at once: both stay.
    let a = first.createGroup(name: "From A")!
    let b = second.createGroup(name: "From B")!
    spin(0.3)
    sync.waitUntilWritten()
    other.waitUntilWritten()
    sync.reconfigure()
    other.reconfigure()
    spin(0.8)
    sync.waitUntilWritten()
    other.waitUntilWritten()
    spin(0.3)
    expectTrue("sync: two groups made at once are both kept, on both Macs",
               [first, second].allSatisfy { $0.group(id: a.id) != nil && $0.group(id: b.id) != nil })
    expect("sync: in the same order on both", first.groups.map(\.name).joined(separator: ","), second.groups.map(\.name).joined(separator: ","))

    // Deleted on one Mac: gone on the other, and no note with it.
    let noteCount = second.notes.count
    try! first.deleteGroup(id: home.id)
    spin(0.3)
    sync.waitUntilWritten()
    other.reconfigure()
    spin(0.8)
    other.waitUntilWritten()
    spin(0.3)
    expectTrue("sync: a deleted group is gone on the other Mac", second.group(id: home.id) == nil)
    expect("sync: and no note went with it", String(second.notes.count), String(noteCount))
    expectTrue("sync: its notes are in none there", second.note(id: inWork.id)?.groupID == nil)
    expectTrue("sync: the file says deleted", { () -> Bool in
        let text = try? String(contentsOf: folder.appendingPathComponent(GroupFile.fileName(for: home.id)), encoding: .utf8)
        return text.flatMap(GroupFile.parse)?.deletedAt != nil
    }())

    // An older file does not undo a newer group.
    let newest = first.group(id: work.id)!
    let stale = NoteGroup(id: work.id, name: "Stale", color: .slate, order: 9, createdAt: newest.createdAt,
                          updatedAt: newest.updatedAt.addingTimeInterval(-3600))
    try! GroupFile.serialized(GroupRecord(group: stale, deletedAt: nil))
        .write(to: folder.appendingPathComponent(GroupFile.fileName(for: work.id)), atomically: true, encoding: .utf8)
    sync.reconfigure()
    spin(0.6)
    sync.waitUntilWritten()
    spin(0.2)
    expect("sync: an older file does not win", first.group(id: work.id)?.name, "Office")
    expect("sync: and the folder is brought up to date", GroupFile.parse((try? String(contentsOf: folder.appendingPathComponent(GroupFile.fileName(for: work.id)), encoding: .utf8)) ?? "")?.group.name, "Office")
    withExtendedLifetime((sync, other)) {}
}

// MARK: - Groups in an archive

@MainActor
func runGroupArchiveTests() {
    let key = SymmetricKey(size: .bits256)
    let work = NoteGroup(name: "Work", color: .cyan, order: 0, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    let home = NoteGroup(name: "Home", color: .lime, order: 1, createdAt: Date(timeIntervalSince1970: 1_790_000_100))
    let inWork = Note(title: "in work", body: "w", groupID: work.id)
    let loose = Note(title: "loose", body: "l")

    let archive = try! NoteArchive.encode(notes: [inWork, loose], groups: [work, home])
    expect("archive: the groups round-trip", try! NoteArchive.decodeGroups(archive).map(\.name).joined(separator: ","), "Work,Home")
    let back = try! NoteArchive.decodeGroups(archive)
    expectTrue("archive: with colour, place and dates", back[0].color == .cyan && back[1].order == 1 && back[0].createdAt == work.createdAt)
    expectTrue("archive: a note's group", try! NoteArchive.decode(archive).first { $0.title == "in work" }?.groupID == work.id)
    expectTrue("archive: a loose note's none", try! NoteArchive.decode(archive).first { $0.title == "loose" }?.groupID == nil)
    expectTrue("archive: no groups, nothing written", !String(data: try! NoteArchive.encode(notes: [loose]), encoding: .utf8)!.contains("\"groups\""))
    expectTrue("archive: a loose note writes no group", !String(data: try! NoteArchive.encode(notes: [loose], groups: [work]), encoding: .utf8)!.contains("groupID"))
    let oldArchive = Data("""
    {"format":"com.keepnote.archive","version":1,"exportedAt":"2026-10-01T10:00:00Z","notes":[{"id":"\(UUID().uuidString)","title":"old","body":"b","color":1,"state":"active","tags":[],"createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-01T10:00:00Z"}]}
    """.utf8)
    expectTrue("archive: one from before groups still reads", (try? NoteArchive.decode(oldArchive).count) == 1)
    expectTrue("archive: and has no groups", (try? NoteArchive.decodeGroups(oldArchive).isEmpty) == true)
    expectTrue("archive: its note is in none", (try? NoteArchive.decode(oldArchive).first?.groupID) == .some(nil))

    // Imported into another Mac: the groups come first, the notes find them.
    let file = scratchDirectory().appendingPathComponent("g.hmnotearchive")
    try! archive.write(to: file)
    let store = reopened(scratchDirectory().appendingPathComponent("i.sqlite"), key: key)
    let result = try! NoteImporter.importContents(of: file, into: store)
    expect("import: the notes come", String(result.applied), "2")
    expect("import: and the groups, in order", store.groups.map(\.name).joined(separator: ","), "Work,Home")
    expectTrue("import: each note in its group", store.note(id: inWork.id)?.groupID == work.id)
    expectTrue("import: the loose one loose", store.note(id: loose.id)?.groupID == nil)
    expect("import: the group holds it", store.notes(inGroup: work.id).map(\.title).joined(), "in work")
    // A newer group here is not undone by an older archive.
    store.renameGroup(id: work.id, to: "Renamed")
    _ = try! NoteImporter.importContents(of: file, into: store)
    expect("import: an older archive does not undo a newer name", store.group(id: work.id)?.name, "Renamed")
    // A group deleted here does not come back from an older archive.
    try! store.deleteGroup(id: home.id)
    _ = try! NoteImporter.importContents(of: file, into: store)
    expectTrue("import: a group deleted here stays deleted", store.group(id: home.id) == nil)

    // The same through the package that carries attachments is the same JSON, so a folder of files is the other way in.
    let folder = scratchDirectory()
    try! GroupFile.serialized(GroupRecord(group: work, deletedAt: nil))
        .write(to: folder.appendingPathComponent(GroupFile.fileName(for: work.id)), atomically: true, encoding: .utf8)
    try! HMNoteFile(note: inWork).serialized().write(to: folder.appendingPathComponent(HMNoteFile(note: inWork).fileName), atomically: true, encoding: .utf8)
    let fresh = reopened(scratchDirectory().appendingPathComponent("f.sqlite"), key: key)
    _ = try! NoteImporter.importContents(of: folder, into: fresh)
    expect("import: a folder's groups come too", fresh.groups.map(\.name).joined(), "Work")
    expectTrue("import: and its notes find them", fresh.note(id: inWork.id)?.groupID == work.id)

    // MARK: The other exports say the group in words

    expectTrue("markdown: says the group", ExportService.markdown(for: inWork, group: "Work").contains("Group: Work"))
    expectTrue("markdown: no group, no line", !ExportService.markdown(for: loose).contains("Group:"))
    expectTrue("text: says the group", ExportService.plainText(for: inWork, group: "Work").contains("Group: Work"))
    expectTrue("text: no group, no line", !ExportService.plainText(for: loose).contains("Group:"))
    let target = scratchDirectory()
    try! ExportService.writePerNote(notes: [inWork, loose], into: target, groups: [work])
    let written = try! String(contentsOf: target.appendingPathComponent("in work.txt"), encoding: .utf8)
    expectTrue("export: a file per note names the group", written.contains("Group: Work"))
    let looseText = try! String(contentsOf: target.appendingPathComponent("loose.txt"), encoding: .utf8)
    expectTrue("export: and a loose note's does not", !looseText.contains("Group:"))
}

// MARK: - Moving notes to groups, from the menus

@MainActor
func runMoveToGroupTests() {
    let store = reopened(scratchDirectory().appendingPathComponent("move.sqlite"), key: SymmetricKey(size: .bits256))
    let work = store.createGroup(name: "Work", color: .red)!
    let home = store.createGroup(name: "Home", color: .teal)!
    let note = try! store.create(title: "n")
    let daily = try! store.create(title: "d", tags: [DailyNotes.tag])
    let coordinator = AppCoordinator(store: store)

    coordinator.moveToGroup([note.id], group: work.id)
    expectTrue("move: a note into a group", store.note(id: note.id)?.groupID == work.id)
    expect("move: said", Announcer.last, "Note moved to Work")
    coordinator.moveToGroup([note.id], group: nil)
    expectTrue("move: and out of every group", store.note(id: note.id)?.groupID == nil)
    expect("move: said", Announcer.last, "Note moved out of its group")
    coordinator.moveToGroup([daily.id], group: home.id)
    expectTrue("move: a daily stays in Daily", store.note(id: daily.id)?.groupID == nil)
    expect("move: and that is said", Announcer.last, "Daily notes stay in Daily")
    coordinator.moveToGroup([note.id, daily.id], group: home.id)
    expectTrue("move: several at once, the daily left out", store.note(id: note.id)?.groupID == home.id && store.note(id: daily.id)?.groupID == nil)

    // The menu every place shares.
    var chosen: [UUID?] = []
    var made = 0
    let target = GroupMenu.Target(choose: { chosen.append($0) }, newGroup: { made += 1 })
    let item = GroupMenu.makeItem(choices: GroupMenu.choices(store.groups), current: home.id, target: target)
    let titles = item.submenu?.items.map(\.title) ?? []
    expect("menu: named", item.title, "Move to Group")
    expect("menu: No Group, the groups in order, New Group…", titles.filter { !$0.isEmpty }.joined(separator: "|"), "No Group|Work|Home|New Group\u{2026}")
    let rows = item.submenu?.items.filter { !$0.isSeparatorItem } ?? []
    expectTrue("menu: the note's group is ticked, No Group is not", rows[2].state == .on && rows[0].state == .off && rows[1].state == .off)
    expectTrue("menu: a swatch in each group's colour", rows[1].image != nil && rows[2].image != nil)
    _ = target.perform(#selector(GroupMenu.Target.choose(_:)), with: rows[1])
    _ = target.perform(#selector(GroupMenu.Target.choose(_:)), with: rows[0])
    _ = target.perform(#selector(GroupMenu.Target.newGroup))
    expectTrue("menu: choosing a group, No Group and New Group… reach the target", chosen == [work.id, nil] && made == 1)
    expectTrue("menu: for a daily it is there and off",
               !GroupMenu.makeItem(choices: [], current: nil, enabled: false, target: target).isEnabled)
    expect("menu: with no groups, only No Group and New Group…",
           GroupMenu.makeItem(choices: [], current: nil, target: target).submenu?.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: "|"),
           "No Group|New Group\u{2026}")
    // A tab's right-click menu has it too.
    let card = NoteCardView(note: store.note(id: note.id)!, height: EdgeMetrics.tabHeight)
    card.groupChoices = GroupMenu.choices(store.groups)
    expect("tab: its group", card.currentGroup.map { store.group(id: $0)?.name ?? "" }, "Home")
}
