import Foundation
import os

/// One copy of the database in the backups folder.
struct Backup: Equatable, Sendable {
    /// Why it was made; part of the file name.
    enum Kind: String, Sendable, CaseIterable {
        /// The one a day, made by itself.
        case daily
        /// Back Up Now, in Settings.
        case manual
        /// Just before the database's layout was brought up to date.
        case migration
        /// The notes as they were just before a restore replaced them.
        case beforeRestore = "before-restore"
    }

    let url: URL
    let date: Date
    let kind: Kind
}

/// Local copies of the database: one a day by itself, one before every
/// change to its layout, one before a restore, and one whenever Back Up Now is
/// pressed — the seven most recent kept, in the database's own folder, under
/// `Backups`. Nothing leaves the Mac.
///
/// A copy is the database itself, written by SQLite (`VACUUM INTO`) from the
/// open connection, so it is whole even while the app writes: the bodies stay
/// sealed with the key in the Keychain, exactly as in the original, and a copy
/// is no easier to read than it.
enum Backups {
    static let keep = 7
    static let folderName = "Backups"
    private static let fileExtension = "sqlite"
    private static let log = Logger(subsystem: "com.keepnote.KeepNote", category: "backups")

    static func directory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    /// `notes-20261021-153012-250-daily.sqlite`, in this Mac's time zone.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    static func fileName(date: Date, kind: Backup.Kind) -> String {
        "notes-\(stamp.string(from: date))-\(kind.rawValue).\(fileExtension)"
    }

    static func parse(_ url: URL) -> Backup? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == fileExtension, name.hasPrefix("notes-") else { return nil }
        let rest = name.dropFirst("notes-".count)
        // yyyyMMdd-HHmmss-SSS is 19 characters, then "-kind".
        guard rest.count > 20 else { return nil }
        let datePart = String(rest.prefix(19))
        let kindPart = String(rest.dropFirst(20))
        guard let date = stamp.date(from: datePart), let kind = Backup.Kind(rawValue: kindPart) else { return nil }
        return Backup(url: url, date: date, kind: kind)
    }

    /// Every backup in `directory`, newest first.
    static func list(in directory: URL) -> [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(parse).sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.path > $1.url.path }
    }

    /// Whether today still needs its copy: none made today, other than the
    /// one before a migration (that is the notes before the update, not today's).
    static func isDailyDue(in directory: URL, now: Date, calendar: Calendar = .current) -> Bool {
        !list(in: directory).contains { $0.kind != .migration && calendar.isDate($0.date, inSameDayAs: now) }
    }

    /// Copies the open database `db` into `directory`, then keeps the newest
    /// `keep`. The copy is written beside its final name and moved in whole,
    /// so a half-written file never counts as a backup.
    @discardableResult
    static func make(from db: SQLiteDatabase, kind: Backup.Kind, in directory: URL, now: Date) throws -> Backup {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var date = now
        var url = directory.appendingPathComponent(fileName(date: date, kind: kind))
        // Two in the same millisecond (a test, or two presses): the later one
        // is a millisecond later.
        while manager.fileExists(atPath: url.path) {
            date = date.addingTimeInterval(0.001)
            url = directory.appendingPathComponent(fileName(date: date, kind: kind))
        }
        let partial = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: partial) }
        let quoted = partial.path.replacingOccurrences(of: "'", with: "''")
        try db.execute("VACUUM INTO '\(quoted)';")
        try manager.moveItem(at: partial, to: url)
        rotate(in: directory)
        log.notice("backup \(kind.rawValue, privacy: .public) written")
        return Backup(url: url, date: date, kind: kind)
    }

    /// The `keep` newest stay; the rest go.
    static func rotate(in directory: URL, keep: Int = keep) {
        for old in list(in: directory).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    // MARK: - Reading a backup

    /// What a backup holds, for the list Restore shows.
    static func noteCount(of url: URL) -> Int? {
        guard let db = try? SQLiteDatabase(readOnlyPath: url.path) else { return nil }
        return try? db.scalarInt("SELECT count(*) FROM notes WHERE deleted_at IS NULL;")
    }

    enum RestoreError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return L("The backup could not be restored: %@. Your notes are as they were.", reason)
            }
        }
    }

    /// The file is a whole KeepNote database: SQLite finds nothing wrong with
    /// it and it has the notes table and a layout version.
    static func validate(_ url: URL) throws {
        let db: SQLiteDatabase
        do {
            db = try SQLiteDatabase(readOnlyPath: url.path)
        } catch {
            throw RestoreError.unreadable(L("it cannot be opened"))
        }
        guard (try? db.scalarString("PRAGMA quick_check;")) == "ok" else {
            throw RestoreError.unreadable(L("it is damaged"))
        }
        let tables = (try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'notes';")) ?? 0
        guard tables == 1, db.userVersion > 0 else {
            throw RestoreError.unreadable(L("it is not a KeepNote database"))
        }
    }

    /// Puts `backup` in place of the database at `databaseURL`, which nothing
    /// may have open (the app does this at launch, before the store opens).
    /// The backup is checked first and copied beside the database; only a
    /// whole, checked copy replaces it, in one move — so a restore that fails
    /// leaves the database exactly as it was.
    static func restore(_ backup: URL, to databaseURL: URL) throws {
        try validate(backup)
        let manager = FileManager.default
        let staged = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(".restoring-\(UUID().uuidString).sqlite")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: backup, to: staged)
        try validate(staged)
        if rename(staged.path, databaseURL.path) != 0 {
            throw RestoreError.unreadable(String(cString: strerror(errno)))
        }
        // The old database's write-ahead log belonged to it, not to the copy
        // now in its place: SQLite must not replay it over the backup.
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(atPath: databaseURL.path + suffix)
        }
        log.notice("backup restored")
    }
}
