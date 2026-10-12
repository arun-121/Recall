import Foundation
import CSQLite

/// SQLite transient destructor sentinel. SQLite needs to copy bound bytes/text
/// because Swift may free the buffer before the statement executes.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin, safe wrapper around a SQLite database connection.
///
/// All access is serialized through a single internal queue so the connection
/// is used from one thread at a time, which keeps the higher layers simple and
/// avoids SQLITE_BUSY under concurrent indexing + searching.
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.recall.sqlite")

    /// Opens (or creates) a database at `path`. Use ":memory:" for tests.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StorageError.openFailed(msg)
        }
        self.db = handle
        // Pragmas: WAL for better read/write concurrency, foreign keys on.
        try execDirect("PRAGMA journal_mode=WAL;")
        try execDirect("PRAGMA foreign_keys=ON;")
        try execDirect("PRAGMA busy_timeout=5000;")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func lastError() -> String {
        guard let db else { return "no connection" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// Runs a raw SQL statement with no bindings and no result rows.
    private func execDirect(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.queryFailed(lastError())
        }
    }

    /// Executes a block with exclusive, serialized access to the connection.
    public func perform<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        try queue.sync {
            try body(db!)
        }
    }

    /// Runs one or more statements with no results (serialized).
    public func exec(_ sql: String) throws {
        try queue.sync { try execDirect(sql) }
    }

    /// Runs `body` inside a transaction on the serial queue, committing on
    /// success and rolling back on any thrown error. The database handle is
    /// passed to `body`; do NOT call `perform`/`exec`/`transaction` from within
    /// `body` as that would re-enter the serial queue and deadlock. Use the
    /// provided handle directly instead.
    public func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            let handle = db!
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                throw StorageError.queryFailed(lastError())
            }
            do {
                let result = try body(handle)
                guard sqlite3_exec(handle, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                    throw StorageError.queryFailed(lastError())
                }
                return result
            } catch {
                _ = sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    /// Prepares a statement for use within the serialized queue. Intended to be
    /// called from inside `perform`/`transaction` bodies.
    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StorageError.queryFailed(lastError())
        }
        return stmt
    }

    /// The row id of the most recent successful INSERT.
    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }
}

// MARK: - Statement binding helpers

extension OpaquePointer {
    func bindText(_ index: Int32, _ value: String) {
        sqlite3_bind_text(self, index, value, -1, SQLITE_TRANSIENT)
    }
    func bindInt(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(self, index, value)
    }
    func bindOptionalInt(_ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(self, index, Int64(value)) }
        else { sqlite3_bind_null(self, index) }
    }
    func bindDouble(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(self, index, value)
    }
    func bindBlob(_ index: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(self, index, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }
    func bindOptionalText(_ index: Int32, _ value: String?) {
        if let value { bindText(index, value) }
        else { sqlite3_bind_null(self, index) }
    }

    func columnText(_ index: Int32) -> String {
        guard let c = sqlite3_column_text(self, index) else { return "" }
        return String(cString: c)
    }
    func columnOptionalText(_ index: Int32) -> String? {
        guard sqlite3_column_type(self, index) != SQLITE_NULL,
              let c = sqlite3_column_text(self, index) else { return nil }
        return String(cString: c)
    }
    func columnInt(_ index: Int32) -> Int64 {
        sqlite3_column_int64(self, index)
    }
    func columnOptionalInt(_ index: Int32) -> Int? {
        guard sqlite3_column_type(self, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(self, index))
    }
    func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(self, index)
    }
    func columnBlob(_ index: Int32) -> Data {
        guard let ptr = sqlite3_column_blob(self, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(self, index))
        return Data(bytes: ptr, count: count)
    }
}
