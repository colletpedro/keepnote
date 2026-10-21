import AppKit
import CryptoKit

// MARK: - Backups

@MainActor
func runBackupTests() {
    final class Clock { var date = Date(timeIntervalSince1970: 1_790_000_000) }
    let key = SymmetricKey(size: .bits256)

    // Seven kept, the newest.
    do {
        let clock = Clock()
        let url = scratchDirectory().appendingPathComponent("notes.sqlite")
        let store = try! NoteStore(databaseURL: url, cipher: BodyCipher(key: key), now: { clock.date })
        _ = try! store.create(title: "a", body: "b")
        expect("backups: a new database has none", String(Backups.list(in: store.backupDirectory).count), "0")
        var made: [Backup] = []
        for _ in 0..<9 {
            made.append(try! store.backUp(kind: .daily))
            clock.date = clock.date.addingTimeInterval(86_400)
        }
        let kept = Backups.list(in: store.backupDirectory)
        expect("backups: seven are kept", String(kept.count), "7")
        expect("backups: the newest seven", kept.map(\.url.lastPathComponent).joined(separator: ","),
               made.suffix(7).reversed().map(\.url.lastPathComponent).joined(separator: ","))
        expectTrue("backups: the two oldest are gone",
                   made.prefix(2).allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        expect("backups: Settings sees the newest", store.lastBackup?.url.lastPathComponent, made.last?.url.lastPathComponent)
        expectTrue("backups: beside the database, in Backups",
                   store.backupDirectory == url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true))

        // Every kind counts towards the seven.
        _ = try! store.backUp(kind: .manual)
        expect("backups: still seven with a manual one", String(Backups.list(in: store.backupDirectory).count), "7")
        expectTrue("backups: and it is the newest", Backups.list(in: store.backupDirectory).first?.kind == .manual)

        // One a day: none due again today; due the next day.
        expectTrue("backups: today has its copy", !Backups.isDailyDue(in: store.backupDirectory, now: clock.date))
        var dailyMade: Backup?
        store.backUpIfDue { dailyMade = $0 }
        spin(0.3)
        expectTrue("backups: no second copy the same day", dailyMade == nil)
        clock.date = clock.date.addingTimeInterval(86_400)
        store.backUpIfDue { dailyMade = $0 }
        for _ in 0..<20 where dailyMade == nil { spin(0.05) }
        expectTrue("backups: the next day's is made by itself", dailyMade?.kind == .daily)
        expect("backups: still seven", String(Backups.list(in: store.backupDirectory).count), "7")
        expectTrue("backups: the name says when and why", Backups.parse(dailyMade!.url)?.date == dailyMade!.date)
    }

    // Before a migration: the database as the earlier version left it.
    do {
        let url = scratchDirectory().appendingPathComponent("notes.sqlite")
        var store: NoteStore? = reopened(url, key: key)
        let id = try! store!.create(title: "Old layout", body: "kept across the update").id
        store!.waitUntilSaved()
        let directory = store!.backupDirectory
        store = nil
        expect("migration: a database already up to date makes no copy", String(Backups.list(in: directory).count), "0")
        // As an earlier KeepNote left it: one version back.
        do {
            let db = try! SQLiteDatabase(path: url.path)
            db.userVersion = NoteSchema.currentVersion - 1
        }
        store = reopened(url, key: key)
        let copies = Backups.list(in: directory)
        expect("migration: one copy before the update", copies.map(\.kind.rawValue).joined(separator: ","), "migration")
        if let copy = copies.first {
            let db = try! SQLiteDatabase(readOnlyPath: copy.url.path)
            expect("migration: the copy is the earlier version", String(db.userVersion), String(NoteSchema.currentVersion - 1))
            expect("migration: with the notes in it", Backups.noteCount(of: copy.url).map(String.init), "1")
        }
        expect("migration: the update went on", store!.note(id: id)?.body, "kept across the update")
        store = nil
        store = reopened(url, key: key)
        expect("migration: once up to date, no more copies", String(Backups.list(in: directory).count), "1")
    }

    // A real restore, into a database of its own.
    do {
        let url = scratchDirectory().appendingPathComponent("notes.sqlite")
        var store: NoteStore? = reopened(url, key: key)
        let kept = try! store!.create(title: "Kept", body: "the secret plan").id
        let edited = try! store!.create(title: "Edited", body: "first version").id
        let backup = try! store!.backUp(kind: .manual)
        // Sealed as the original: the body's words are nowhere in the file.
        let bytes = try! Data(contentsOf: backup.url)
        expectTrue("restore: the copy is sealed like the database", bytes.range(of: Data("the secret plan".utf8)) == nil)
        expect("restore: the list counts its notes", Backups.noteCount(of: backup.url).map(String.init), "2")

        // Later: a note added, one changed, one deleted for good.
        _ = try! store!.create(title: "Later", body: "after the backup")
        try! store!.setBody("second version", id: edited)
        try! store!.delete(id: kept)
        try! store!.purge(id: kept)
        store!.waitUntilSaved()
        let directory = store!.backupDirectory
        store = nil

        try! Backups.restore(backup.url, to: url)
        store = reopened(url, key: key)
        expect("restore: the notes are the backup's", String(store!.notes.count), "2")
        expect("restore: the deleted one is back, and readable", store!.note(id: kept)?.body, "the secret plan")
        expect("restore: the changed one as it was", store!.note(id: edited)?.body, "first version")
        expectTrue("restore: nothing locked", store!.notes.allSatisfy { !$0.isLocked })
        expectTrue("restore: the backup itself stays", FileManager.default.fileExists(atPath: backup.url.path))
        expectTrue("restore: no leftover beside the database",
                   (try! FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))
                       .allSatisfy { !$0.hasPrefix(".restoring") })
        // Writing after the restore works as ever.
        try! store!.setBody("edited after", id: edited)
        store!.waitUntilSaved()
        store = nil
        expect("restore: and the restored database takes new edits", reopened(url, key: key).note(id: edited)?.body, "edited after")
        _ = directory
    }

    // A restore that fails leaves the database as it was.
    do {
        let url = scratchDirectory().appendingPathComponent("notes.sqlite")
        var store: NoteStore? = reopened(url, key: key)
        let id = try! store!.create(title: "Current", body: "do not lose me").id
        store!.waitUntilSaved()
        let good = try! store!.backUp(kind: .manual)
        let directory = store!.backupDirectory
        store = nil
        let before = try! Data(contentsOf: url)

        let garbage = directory.appendingPathComponent("garbage.sqlite")
        try! Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37) }).write(to: garbage)
        let half = directory.appendingPathComponent("half.sqlite")
        let whole = try! Data(contentsOf: good.url)
        try! whole.prefix(whole.count / 2).write(to: half)
        let foreign = directory.appendingPathComponent("foreign.sqlite")
        do {
            let db = try! SQLiteDatabase(path: foreign.path)
            try! db.execute("CREATE TABLE other (x INTEGER);")
        }
        let missing = directory.appendingPathComponent("missing.sqlite")

        for (name, file) in [("not a database", garbage), ("cut short", half), ("another app's", foreign), ("gone", missing)] {
            var failed = false
            do { try Backups.restore(file, to: url) } catch { failed = true }
            expectTrue("restore fails: \(name)", failed)
            expectTrue("restore fails: \(name): the database is untouched", (try? Data(contentsOf: url)) == before)
        }
        let after = reopened(url, key: key)
        expect("restore fails: the notes are as they were", after.note(id: id)?.body, "do not lose me")
        expect("restore fails: and only those", String(after.notes.count), "1")
        // The reason, in words.
        var message = ""
        do { try Backups.restore(garbage, to: url) } catch { message = error.localizedDescription }
        expectTrue("restore fails: says the notes are as they were (\(message))", message.contains("Your notes are as they were"))
    }
}
