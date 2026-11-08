import Foundation
import SQLite3

/// A SQLite database with one lock, for the stores built on it. Safe to call from any thread, but
/// everything but `locked` itself expects the lock to be held by the caller.
public final class SQLiteDatabase: @unchecked Sendable {
    public enum Synchronous: String, Sendable {
        /// Survives app crashes; only a power loss can drop the last few writes.
        case normal = "NORMAL"
        case full = "FULL"
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    private var inTransaction = false
    private var statementFailed = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens the database in WAL mode. `synchronous` is SQLite's default (FULL) unless given.
    public init(path: String, synchronous: Synchronous? = nil) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            fatalError("Could not open database at \(path)")
        }
        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        if let synchronous { sqlite3_exec(db, "PRAGMA synchronous = \(synchronous.rawValue)", nil, nil, nil) }
    }

    public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Statements (call with lock held)

    /// Runs statements that take no arguments and return nothing, such as the schema.
    public func executeScript(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("SQLite script failed: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
        }
    }

    /// Inside a transaction, a failure makes the rest of it be skipped and rolled back.
    public func execute(_ sql: String, _ args: [Any?] = []) {
        guard !statementFailed else { return }
        guard let stmt = prepare(sql, args) else {
            statementFailed = inTransaction
            return
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("SQLite step failed: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
            statementFailed = inTransaction
        }
    }

    public func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(row(stmt)) }
        return results
    }

    public struct StatementFailure: Error {
        public let message: String
    }

    /// Runs one statement for each row, prepared once, stopping at the first failure.
    public func insert<Row>(_ sql: String, _ args: [Any?] = [], rows: [Row], bind: (OpaquePointer, Row) -> Void) throws {
        guard !statementFailed else { return }
        guard let stmt = prepare(sql, args) else { throw StatementFailure(message: "Couldn't prepare \(sql)") }
        defer { sqlite3_finalize(stmt) }
        for row in rows {
            bind(stmt, row)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StatementFailure(message: "\(String(cString: sqlite3_errmsg(db))) — \(sql)")
            }
            sqlite3_reset(stmt)
        }
    }

    /// How many rows the last statement changed.
    public var changes: Int { Int(sqlite3_changes(db)) }

    /// All or nothing: if a statement fails or `body` throws, the rest is skipped and things are
    /// left as they were. Returns whether it was saved.
    public func transaction(_ body: () throws -> Void) -> Bool {
        inTransaction = true
        defer {
            inTransaction = false
            statementFailed = false
        }
        execute("BEGIN")
        guard !statementFailed else { return false }
        do {
            try body()
            execute("COMMIT")
        } catch {
            print("SQLite transaction failed: \(error)")
            statementFailed = true
        }
        guard statementFailed else { return true }
        statementFailed = false
        inTransaction = false
        execute("ROLLBACK")
        return false
    }

    // MARK: - Migrations (call with lock held)

    public var userVersion: Int {
        query("PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    /// Runs `body` if the database is older than `version`, in one transaction that sets the
    /// version only if all of it succeeded. Returns whether the database is at `version` or later.
    @discardableResult
    public func migrate(to version: Int, _ body: () throws -> Void) -> Bool {
        guard userVersion < version else { return true }
        return transaction {
            try body()
            execute("PRAGMA user_version = \(version)")
        }
    }

    /// Adds a column unless the table has it, for the tables from before versions were recorded.
    public func addColumn(_ column: String, definition: String, to table: String) {
        let present = query("PRAGMA table_info(\(table))") { Self.text($0, 1) }.contains(column)
        if !present { execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)") }
    }

    // MARK: - Binding and reading

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
            return nil
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as String: Self.bind(stmt!, index, v)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Data: Self.bind(stmt!, index, v)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    public static func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(stmt, index, text, -1, transient) } else { sqlite3_bind_null(stmt, index) }
    }

    public static func bind(_ stmt: OpaquePointer, _ index: Int32, _ data: Data?) {
        guard let data else { return _ = sqlite3_bind_null(stmt, index) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
    }

    public static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    public static func double(_ stmt: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, column)
    }

    public static func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }
}
