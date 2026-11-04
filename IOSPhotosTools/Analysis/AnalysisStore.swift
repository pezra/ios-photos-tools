import Foundation
import SQLite3

/// Cache of photo analyses, so a rescan only looks at new or edited photos, plus the near
/// duplicates the user has decided to keep.
///
/// Safe to call from any thread.
final class AnalysisStore: @unchecked Sendable {
    static let shared = AnalysisStore()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("analysis.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            fatalError("Could not open analysis database at \(path)")
        }
        // WAL with NORMAL sync survives app crashes; only a power loss can drop the last few writes.
        sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS analyses (
                id TEXT PRIMARY KEY,
                modified_at REAL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                dhash INTEGER NOT NULL,
                feature_print BLOB NOT NULL,
                aesthetics REAL NOT NULL,
                is_utility INTEGER NOT NULL,
                face_quality REAL,
                sharpness REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS kept (
                id TEXT PRIMARY KEY
            );
            """, nil, nil, nil)
        // Columns added after the first release. Each fails harmlessly once it exists. Rows from
        // before have version 1, so tools that need the new columns re-analyze them.
        for column in [
            "face_count INTEGER NOT NULL DEFAULT 0",
            "face_area REAL NOT NULL DEFAULT 0",
            "person_area REAL NOT NULL DEFAULT 0",
            "version INTEGER NOT NULL DEFAULT 1",
        ] {
            sqlite3_exec(db, "ALTER TABLE analyses ADD COLUMN \(column)", nil, nil, nil)
        }
    }

    private static let columns = """
        id, modified_at, width, height, dhash, feature_print, aesthetics, is_utility, face_quality, sharpness,
        face_count, face_area, person_area, version
        """

    func all() -> [String: PhotoAnalysis] {
        locked {
            let rows = query("SELECT \(Self.columns) FROM analyses", [], analysis)
            return Dictionary(rows.map { ($0.assetID, $0) }, uniquingKeysWith: { $1 })
        }
    }

    /// Cached analyses of just these photos.
    func analyses(_ ids: [String]) -> [String: PhotoAnalysis] {
        locked {
            var result: [String: PhotoAnalysis] = [:]
            for id in ids {
                if let row = query("SELECT \(Self.columns) FROM analyses WHERE id = ?", [id], analysis).first {
                    result[id] = row
                }
            }
            return result
        }
    }

    func save(_ analysis: PhotoAnalysis) {
        let featurePrint = analysis.featurePrint.withUnsafeBufferPointer { Data(buffer: $0) }
        locked {
            execute("""
                INSERT OR REPLACE INTO analyses (\(Self.columns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [analysis.assetID, analysis.modifiedAt, analysis.pixelWidth, analysis.pixelHeight,
                      Int(Int64(bitPattern: analysis.dHash)), featurePrint, Double(analysis.aesthetics),
                      analysis.isUtility ? 1 : 0, analysis.faceQuality.map { Double($0) }, analysis.sharpness,
                      analysis.faceCount, Double(analysis.faceArea), Double(analysis.personArea), analysis.version])
        }
    }

    /// Photos the user chose to keep even though they're near duplicates.
    func keptIDs() -> Set<String> {
        locked { Set(query("SELECT id FROM kept") { text($0, 0) ?? "" }) }
    }

    func setKept(_ id: String, _ kept: Bool) {
        locked {
            if kept {
                execute("INSERT OR IGNORE INTO kept (id) VALUES (?)", [id])
            } else {
                execute("DELETE FROM kept WHERE id = ?", [id])
            }
        }
    }

    /// Forgets photos that are no longer in the library.
    func remove(_ ids: [String]) {
        locked {
            execute("BEGIN")
            for id in ids {
                execute("DELETE FROM analyses WHERE id = ?", [id])
                execute("DELETE FROM kept WHERE id = ?", [id])
            }
            execute("COMMIT")
        }
    }

    // MARK: - SQLite helpers (call with lock held)

    private func analysis(_ stmt: OpaquePointer) -> PhotoAnalysis {
        PhotoAnalysis(assetID: text(stmt, 0) ?? "",
                      modifiedAt: double(stmt, 1),
                      pixelWidth: Int(sqlite3_column_int64(stmt, 2)),
                      pixelHeight: Int(sqlite3_column_int64(stmt, 3)),
                      dHash: UInt64(bitPattern: sqlite3_column_int64(stmt, 4)),
                      featurePrint: floats(stmt, 5),
                      aesthetics: Float(sqlite3_column_double(stmt, 6)),
                      isUtility: sqlite3_column_int(stmt, 7) != 0,
                      faceQuality: double(stmt, 8).map { Float($0) },
                      faceCount: Int(sqlite3_column_int64(stmt, 10)),
                      faceArea: Float(sqlite3_column_double(stmt, 11)),
                      personArea: Float(sqlite3_column_double(stmt, 12)),
                      sharpness: sqlite3_column_double(stmt, 9),
                      version: Int(sqlite3_column_int64(stmt, 13)))
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
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), Self.transient) }
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

    private func double(_ stmt: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, column)
    }

    private func floats(_ stmt: OpaquePointer, _ column: Int32) -> [Float] {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return [] }
        let byteCount = Int(sqlite3_column_bytes(stmt, column))
        var values = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { memcpy($0.baseAddress!, bytes, $0.count) }
        return values
    }
}
