import Foundation
import SQLite3

enum ResourceState: Int {
    case pending = 0
    case uploading = 1
    case done = 2
    case failed = 3
}

/// One file (photo, video, Live Photo movie, edited render, …) belonging to a library asset.
struct ResourceRow {
    let id: String
    let assetID: String
    let s3Key: String
}

/// Persistent record of what has been backed up, in a small SQLite database.
///
/// An asset is complete once every one of its resources has uploaded. Safe to call from any thread.
final class BackupStore: @unchecked Sendable {
    static let shared = BackupStore()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("backup.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            fatalError("Could not open backup database at \(path)")
        }
        sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                completed_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS resources (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL,
                s3_key TEXT NOT NULL,
                state INTEGER NOT NULL,
                staged_name TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS resources_asset ON resources(asset_id);
            CREATE INDEX IF NOT EXISTS resources_state ON resources(state);
            """, nil, nil, nil)
    }

    // MARK: - Queries

    func completedAssetIDs() -> Set<String> {
        locked { Set(query("SELECT id FROM assets") { text($0, 0) ?? "" }) }
    }

    func completedAssetCount() -> Int {
        locked { query("SELECT COUNT(*) FROM assets") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    func count(_ state: ResourceState) -> Int {
        locked {
            query("SELECT COUNT(*) FROM resources WHERE state = ?", [state.rawValue]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    func states(forAsset assetID: String) -> [String: ResourceState] {
        locked {
            let rows = query("SELECT id, state FROM resources WHERE asset_id = ?", [assetID]) {
                (text($0, 0) ?? "", ResourceState(rawValue: Int(sqlite3_column_int($0, 1))) ?? .pending)
            }
            return Dictionary(rows, uniquingKeysWith: { $1 })
        }
    }

    func uploadingResources() -> [(id: String, stagedName: String?)] {
        locked {
            query("SELECT id, staged_name FROM resources WHERE state = ?", [ResourceState.uploading.rawValue]) {
                (id: text($0, 0) ?? "", stagedName: text($0, 1))
            }
        }
    }

    func stagedName(forResource id: String) -> String? {
        locked { query("SELECT staged_name FROM resources WHERE id = ?", [id]) { text($0, 0) }.first ?? nil }
    }

    func lastError() -> String? {
        locked {
            query("SELECT last_error FROM resources WHERE state = ? ORDER BY updated_at DESC LIMIT 1",
                  [ResourceState.failed.rawValue]) { text($0, 0) }.first ?? nil
        }
    }

    // MARK: - Updates

    /// Records resources for an asset; keys of not-yet-uploaded resources are refreshed.
    func register(_ rows: [ResourceRow]) {
        locked {
            for row in rows {
                execute("""
                    INSERT INTO resources (id, asset_id, s3_key, state, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET s3_key = excluded.s3_key WHERE state != \(ResourceState.done.rawValue)
                    """, [row.id, row.assetID, row.s3Key, ResourceState.pending.rawValue, now])
            }
        }
    }

    func markUploading(_ id: String, stagedName: String) {
        locked {
            execute("UPDATE resources SET state = ?, staged_name = ?, updated_at = ? WHERE id = ?",
                    [ResourceState.uploading.rawValue, stagedName, now, id])
        }
    }

    func markDone(_ id: String) {
        locked {
            execute("UPDATE resources SET state = ?, staged_name = NULL, last_error = NULL, updated_at = ? WHERE id = ?",
                    [ResourceState.done.rawValue, now, id])
            guard let assetID = query("SELECT asset_id FROM resources WHERE id = ?", [id], { text($0, 0) }).first ?? nil else { return }
            let remaining = query("SELECT COUNT(*) FROM resources WHERE asset_id = ? AND state != ?",
                                  [assetID, ResourceState.done.rawValue]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
            if remaining == 0 { completeAsset(assetID) }
        }
    }

    func markFailed(_ id: String, error: String) {
        locked {
            execute("""
                UPDATE resources SET state = ?, staged_name = NULL, attempts = attempts + 1, last_error = ?, updated_at = ?
                WHERE id = ?
                """, [ResourceState.failed.rawValue, error, now, id])
        }
    }

    func resetToPending(_ id: String) {
        locked {
            execute("UPDATE resources SET state = ?, staged_name = NULL, updated_at = ? WHERE id = ?",
                    [ResourceState.pending.rawValue, now, id])
        }
    }

    /// For assets with nothing to upload.
    func markAssetComplete(_ assetID: String) {
        locked { completeAsset(assetID) }
    }

    /// Forgets all history so everything is uploaded again (e.g. after switching buckets).
    func reset() {
        locked {
            execute("DELETE FROM resources WHERE state != ?", [ResourceState.uploading.rawValue])
            execute("DELETE FROM assets")
        }
    }

    // MARK: - SQLite helpers (call with lock held)

    private var now: Double { Date().timeIntervalSince1970 }

    private func completeAsset(_ assetID: String) {
        execute("INSERT OR REPLACE INTO assets (id, completed_at) VALUES (?, ?)", [assetID, now])
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
            return nil
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func execute(_ sql: String, _ args: [Any?] = []) {
        guard let stmt = prepare(sql, args) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("SQLite step failed: \(String(cString: sqlite3_errmsg(db))) — \(sql)")
        }
    }

    private func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { results.append(row(stmt)) }
        return results
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
}
