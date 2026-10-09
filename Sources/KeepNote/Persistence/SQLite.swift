import Foundation
import SQLite3

/// Tells SQLite to copy bound blobs/strings instead of retaining our pointers.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteError: LocalizedError {
    let code: Int32
    let message: String
    let sql: String?

    var errorDescription: String? {
        if let sql {
            return "SQLite error \(code): \(message) — while running: \(sql)"
        }
        return "SQLite error \(code): \(message)"
    }
}

/// A deliberately small wrapper over the SQLite C API.
///
/// GRDB would do this and more, but the app ships with no third-party code, so
/// the surface here is kept to exactly what `NoteStore` needs.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if handle != nil { sqlite3_close_v2(handle) }
            handle = nil
            throw SQLiteError(code: result, message: message, sql: nil)
        }
        // WAL survives crashes better and lets a read run while a write lands.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA busy_timeout = 3000;")
    }

    deinit {
        if handle != nil { sqlite3_close_v2(handle) }
    }

    var userVersion: Int32 {
        get {
            (try? scalarInt("PRAGMA user_version;")).map(Int32.init) ?? 0
        }
        set {
            try? execute("PRAGMA user_version = \(newValue);")
        }
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw SQLiteError(code: result, message: message, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            throw SQLiteError(code: result, message: message, sql: sql)
        }
        return SQLiteStatement(handle: statement, sql: sql, database: handle)
    }

    /// Runs a statement that returns nothing.
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(bindings)
        _ = try statement.step()
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], _ transform: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(bindings)
        var results: [T] = []
        while try statement.step() {
            results.append(try transform(statement))
        }
        return results
    }

    func scalarInt(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(bindings)
        guard try statement.step() else { return 0 }
        return statement.int(at: 0)
    }

    /// All-or-nothing. A throwing body rolls back, which is what keeps the
    /// notes table and the FTS index from drifting apart.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

/// A value that can be bound to a statement parameter.
enum SQLiteValue {
    case null
    case integer(Int)
    case real(Double)
    case text(String)
    case blob(Data)

    static func date(_ value: Date) -> SQLiteValue { .real(value.timeIntervalSince1970) }
    static func optionalDate(_ value: Date?) -> SQLiteValue {
        value.map { .real($0.timeIntervalSince1970) } ?? .null
    }
    static func uuid(_ value: UUID) -> SQLiteValue { .text(value.uuidString) }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    private let sql: String
    private let database: OpaquePointer?
    private var finalized = false

    init(handle: OpaquePointer, sql: String, database: OpaquePointer?) {
        self.handle = handle
        self.sql = sql
        self.database = database
    }

    deinit { finalize() }

    func finalize() {
        guard !finalized else { return }
        finalized = true
        sqlite3_finalize(handle)
    }

    func bindAll(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    func bind(_ value: SQLiteValue, at index: Int32) throws {
        let result: Int32
        switch value {
        case .null:
            result = sqlite3_bind_null(handle, index)
        case .integer(let int):
            result = sqlite3_bind_int64(handle, index, Int64(int))
        case .real(let double):
            result = sqlite3_bind_double(handle, index, double)
        case .text(let string):
            result = sqlite3_bind_text(handle, index, string, -1, SQLITE_TRANSIENT)
        case .blob(let data):
            result = data.isEmpty
                ? sqlite3_bind_zeroblob(handle, index, 0)
                : data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
        }
        guard result == SQLITE_OK else {
            throw SQLiteError(code: result, message: errorMessage(), sql: sql)
        }
    }

    /// `true` while rows keep coming.
    @discardableResult
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: result, message: errorMessage(), sql: sql)
        }
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func int(at index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func string(at index: Int32) -> String {
        guard let cString = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: cString)
    }

    func data(at index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    func date(at index: Int32) -> Date {
        Date(timeIntervalSince1970: double(at: index))
    }

    func optionalDate(at index: Int32) -> Date? {
        isNull(at: index) ? nil : date(at: index)
    }

    func uuid(at index: Int32) -> UUID? {
        UUID(uuidString: string(at: index))
    }

    private func errorMessage() -> String {
        guard let database else { return "unknown error" }
        return String(cString: sqlite3_errmsg(database))
    }
}
