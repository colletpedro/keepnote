import Foundation

/// Schema migrations, applied in order and tracked by `PRAGMA user_version`.
///
/// The body is the only encrypted column. Everything else stays queryable, and
/// that is deliberate: it is what lets the stack order, the state filter and
/// the title/tag index work without ever touching the key.
enum NoteSchema {
    static let currentVersion: Int32 = 10

    static func migrate(_ db: SQLiteDatabase) throws {
        if db.userVersion < 1 {
            try migrateToV1(db)
            db.userVersion = 1
        }
        if db.userVersion < 2 {
            try migrateToV2(db)
            db.userVersion = 2
        }
        if db.userVersion < 3 {
            try migrateToV3(db)
            db.userVersion = 3
        }
        if db.userVersion < 4 {
            try migrateToV4(db)
            db.userVersion = 4
        }
        if db.userVersion < 5 {
            try migrateToV5(db)
            db.userVersion = 5
        }
        if db.userVersion < 6 {
            try migrateToV6(db)
            db.userVersion = 6
        }
        if db.userVersion < 7 {
            try migrateToV7(db)
            db.userVersion = 7
        }
        if db.userVersion < 8 {
            try migrateToV8(db)
            db.userVersion = 8
        }
        if db.userVersion < 9 {
            try migrateToV9(db)
            db.userVersion = 9
        }
        if db.userVersion < 10 {
            try migrateToV10(db)
            db.userVersion = 10
        }
    }

    /// The daily template: one row at most, the text sealed like a note body.
    /// It is not a note, so it has no row in `notes`.
    private static func migrateToV10(_ db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS daily_template (
            id              INTEGER PRIMARY KEY CHECK (id = 1),
            body_ciphertext BLOB NOT NULL,
            nonce           BLOB NOT NULL,
            updated_at      REAL NOT NULL
        );
        """)
    }

    /// The date the text last changed, apart from `updated_at`, which sync
    /// compares and which pinning, keeping and archiving also move. Existing
    /// notes start with their `updated_at`: the best date there is, since the
    /// two were one column until now.
    private static func migrateToV9(_ db: SQLiteDatabase) throws {
        try db.execute("""
        ALTER TABLE notes ADD COLUMN edited_at REAL;
        UPDATE notes SET edited_at = updated_at;
        """)
    }

    /// The day the time rule archived a note, as `yyyy-MM-dd`, for the Archive
    /// to say so. Notes already archived get none.
    private static func migrateToV8(_ db: SQLiteDatabase) throws {
        try db.execute("ALTER TABLE notes ADD COLUMN auto_archived_day TEXT;")
    }

    /// The day a note was last opened, as `yyyy-MM-dd`. Existing rows get
    /// none; a note without one is given the day it is first loaded on
    /// (`NoteStore.reload`), which is when its time starts counting.
    private static func migrateToV7(_ db: SQLiteDatabase) throws {
        try db.execute("ALTER TABLE notes ADD COLUMN last_opened_day TEXT;")
    }

    /// Pin to Center: when the note was pinned, as seconds since 1970 like the
    /// other dates; `NULL` for a note that is not.
    private static func migrateToV6(_ db: SQLiteDatabase) throws {
        try db.execute("ALTER TABLE notes ADD COLUMN pinned_at REAL;")
    }

    /// Keep on Deck: a note with it on is never archived by the time rule.
    private static func migrateToV5(_ db: SQLiteDatabase) throws {
        try db.execute("ALTER TABLE notes ADD COLUMN keep_on_deck INTEGER NOT NULL DEFAULT 0;")
    }

    /// Daily notes: the local day a note received the `daily` tag, as
    /// `yyyy-MM-dd`, and whether a daily was brought back to the deck by hand.
    /// Existing rows get neither; a note already tagged `daily` is given the
    /// day it is first loaded on (`NoteStore.reload`).
    private static func migrateToV4(_ db: SQLiteDatabase) throws {
        try db.execute("""
        ALTER TABLE notes ADD COLUMN daily_day TEXT;
        ALTER TABLE notes ADD COLUMN daily_kept INTEGER NOT NULL DEFAULT 0;
        """)
    }

    /// The title index used to hold `displayTitle`, which falls back to the
    /// first body line for untitled notes — plaintext from the encrypted body
    /// written to disk. Rebuilt from the `title` column alone.
    private static func migrateToV3(_ db: SQLiteDatabase) throws {
        guard hasFullTextIndex(db) else { return }
        try db.transaction {
            try db.execute("DELETE FROM notes_fts;")
            try db.execute("""
            INSERT INTO notes_fts (note_id, title, tags)
            SELECT id, title, replace(tags, ',', ' ') FROM notes WHERE deleted_at IS NULL;
            """)
        }
    }

    /// The palette went from eight colours to five. `NoteColor.resolve` already
    /// folds the retired raw values on read, but rewriting them here means the
    /// database stops carrying colours the app can no longer produce.
    private static func migrateToV2(_ db: SQLiteDatabase) throws {
        try db.execute("""
        UPDATE notes SET color = 1 WHERE color = 0;
        UPDATE notes SET color = 2 WHERE color = 3;
        UPDATE notes SET color = 6 WHERE color = 7;
        """)
    }

    private static func migrateToV1(_ db: SQLiteDatabase) throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS notes (
            id              TEXT PRIMARY KEY NOT NULL,
            title           TEXT NOT NULL DEFAULT '',
            body_ciphertext BLOB NOT NULL,
            nonce           BLOB NOT NULL,
            color           INTEGER NOT NULL DEFAULT 0,
            state           TEXT NOT NULL DEFAULT 'active',
            sort_index      INTEGER NOT NULL DEFAULT 0,
            tags            TEXT NOT NULL DEFAULT '',
            created_at      REAL NOT NULL,
            updated_at      REAL NOT NULL,
            deleted_at      REAL
        );

        CREATE INDEX IF NOT EXISTS notes_state_sort ON notes (state, sort_index);
        CREATE INDEX IF NOT EXISTS notes_updated    ON notes (updated_at);
        CREATE INDEX IF NOT EXISTS notes_deleted    ON notes (deleted_at);

        CREATE TABLE IF NOT EXISTS tombstones (
            id         TEXT PRIMARY KEY NOT NULL,
            deleted_at REAL NOT NULL
        );
        """)

        // Title and tags only. Indexing the body would write the plaintext we
        // just encrypted straight back to disk; body search runs in memory.
        try? db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5 (
            note_id UNINDEXED,
            title,
            tags,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """)
    }

    /// FTS5 is compiled into the system SQLite, but the app must not fall over
    /// if that ever changes — `NoteStore` degrades to an in-memory scan.
    static func hasFullTextIndex(_ db: SQLiteDatabase) -> Bool {
        let count = (try? db.scalarInt(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='notes_fts';"
        )) ?? 0
        return count > 0
    }
}
