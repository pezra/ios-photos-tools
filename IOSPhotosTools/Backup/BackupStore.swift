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
                completed_at REAL NOT NULL,
                modified_at REAL
            );
            CREATE TABLE IF NOT EXISTS resources (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL,
                s3_key TEXT NOT NULL,
                state INTEGER NOT NULL,
                staged_name TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                updated_at REAL NOT NULL,
                sha256 TEXT,
                asset_modified_at REAL
            );
            CREATE INDEX IF NOT EXISTS resources_asset ON resources(asset_id);
            CREATE INDEX IF NOT EXISTS resources_state ON resources(state);
            CREATE TABLE IF NOT EXISTS drive_assets (
                drive_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                completed_at REAL NOT NULL,
                modified_at REAL,
                PRIMARY KEY (drive_id, asset_id)
            );
            CREATE TEMP TABLE library (id TEXT PRIMARY KEY);
            """, nil, nil, nil)
        // Columns added after the first version; these fail harmlessly when already present.
        sqlite3_exec(db, "ALTER TABLE assets ADD COLUMN modified_at REAL", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE resources ADD COLUMN sha256 TEXT", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE resources ADD COLUMN asset_modified_at REAL", nil, nil, nil)
    }

    // MARK: - Queries

    /// Completed assets mapped to the asset modification date they were backed up at
    /// (nil if unknown, which forces a recheck).
    func completedAssets() -> [String: Double?] {
        locked {
            let rows = query("SELECT id, modified_at FROM assets") { stmt -> (String, Double?) in
                let modified = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
                return (text(stmt, 0) ?? "", modified)
            }
            return Dictionary(rows, uniquingKeysWith: { $1 })
        }
    }

    func count(_ state: ResourceState) -> Int {
        locked {
            query("SELECT COUNT(*) FROM resources WHERE state = ?", [state.rawValue]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    /// State and content hash of the last upload, by resource ID.
    func resources(forAsset assetID: String) -> [String: (state: ResourceState, sha256: String?)] {
        locked {
            let rows = query("SELECT id, state, sha256 FROM resources WHERE asset_id = ?", [assetID]) {
                (text($0, 0) ?? "", (ResourceState(rawValue: Int(sqlite3_column_int($0, 1))) ?? .pending, text($0, 2)))
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

    /// Records resources for an asset at its current modification date; keys of not-yet-uploaded
    /// resources are refreshed.
    func register(_ rows: [ResourceRow], assetID: String, assetModifiedAt: Double?) {
        locked {
            for row in rows {
                execute("""
                    INSERT INTO resources (id, asset_id, s3_key, state, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET s3_key = excluded.s3_key WHERE state != \(ResourceState.done.rawValue)
                    """, [row.id, row.assetID, row.s3Key, ResourceState.pending.rawValue, now])
            }
            execute("UPDATE resources SET asset_modified_at = ? WHERE asset_id = ?", [assetModifiedAt, assetID])
        }
    }

    func markUploading(_ id: String, stagedName: String, sha256: String?) {
        locked {
            execute("UPDATE resources SET state = ?, staged_name = ?, sha256 = ?, updated_at = ? WHERE id = ?",
                    [ResourceState.uploading.rawValue, stagedName, sha256, now, id])
        }
    }

    func markDone(_ id: String) {
        locked {
            execute("UPDATE resources SET state = ?, staged_name = NULL, last_error = NULL, updated_at = ? WHERE id = ?",
                    [ResourceState.done.rawValue, now, id])
            guard let assetID = query("SELECT asset_id FROM resources WHERE id = ?", [id], { text($0, 0) }).first ?? nil else { return }
            completeAssetIfFinished(assetID)
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
    func markAssetComplete(_ assetID: String, modifiedAt: Double?) {
        locked {
            execute("INSERT OR REPLACE INTO assets (id, completed_at, modified_at) VALUES (?, ?, ?)", [assetID, now, modifiedAt])
        }
    }

    /// Marks the asset complete if every one of its resources has uploaded.
    func markAssetCompleteIfFinished(_ assetID: String) {
        locked { completeAssetIfFinished(assetID) }
    }

    /// Forgets all history so everything is uploaded again (e.g. after switching buckets).
    func reset() {
        locked {
            execute("DELETE FROM resources WHERE state != ?", [ResourceState.uploading.rawValue])
            execute("DELETE FROM assets")
        }
    }

    // MARK: - USB drive copies

    /// Assets copied to the drive, mapped to the asset modification date they were copied at.
    func completedDriveAssets(driveID: String) -> [String: Double?] {
        locked {
            let rows = query("SELECT asset_id, modified_at FROM drive_assets WHERE drive_id = ?", [driveID]) { stmt -> (String, Double?) in
                let modified = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
                return (text(stmt, 0) ?? "", modified)
            }
            return Dictionary(rows, uniquingKeysWith: { $1 })
        }
    }

    func markDriveAssetComplete(_ assetID: String, driveID: String, modifiedAt: Double?) {
        locked {
            execute("INSERT OR REPLACE INTO drive_assets (drive_id, asset_id, completed_at, modified_at) VALUES (?, ?, ?, ?)",
                    [driveID, assetID, now, modifiedAt])
        }
    }

    /// Forgets what was copied to drives other than `driveID` (all drives if nil).
    func forgetDrives(except driveID: String?) {
        locked { execute("DELETE FROM drive_assets WHERE drive_id IS NOT ?", [driveID]) }
    }

    // MARK: - Coverage

    /// How many photos in the library are backed up where.
    struct Coverage: Equatable {
        var total = 0
        var cloud = 0
        var drive = 0
        var both = 0

        var cloudOnly: Int { cloud - both }
        var driveOnly: Int { drive - both }
        var nowhere: Int { total - cloud - drive + both }
    }

    /// Replaces the IDs of the assets currently in the photo library, which `coverage` counts
    /// against (so deleted photos aren't counted).
    func setLibraryAssets(_ ids: [String]) {
        locked {
            execute("BEGIN")
            execute("DELETE FROM library")
            for id in ids { execute("INSERT OR IGNORE INTO library (id) VALUES (?)", [id]) }
            execute("COMMIT")
        }
    }

    func coverage(driveID: String?) -> Coverage {
        locked {
            query("""
                SELECT COUNT(*), COUNT(a.id), COUNT(d.asset_id), SUM(a.id IS NOT NULL AND d.asset_id IS NOT NULL)
                FROM library l
                LEFT JOIN assets a ON a.id = l.id
                LEFT JOIN drive_assets d ON d.drive_id = ? AND d.asset_id = l.id
                """, [driveID]) {
                Coverage(total: Int(sqlite3_column_int64($0, 0)), cloud: Int(sqlite3_column_int64($0, 1)),
                         drive: Int(sqlite3_column_int64($0, 2)), both: Int(sqlite3_column_int64($0, 3)))
            }.first ?? Coverage()
        }
    }

    // MARK: - SQLite helpers (call with lock held)

    private var now: Double { Date().timeIntervalSince1970 }

    private func completeAssetIfFinished(_ assetID: String) {
        let remaining = query("SELECT COUNT(*) FROM resources WHERE asset_id = ? AND state != ?",
                              [assetID, ResourceState.done.rawValue]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard remaining == 0 else { return }
        execute("""
            INSERT OR REPLACE INTO assets (id, completed_at, modified_at)
            SELECT ?, ?, MAX(asset_modified_at) FROM resources WHERE asset_id = ?
            """, [assetID, now, assetID])
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
