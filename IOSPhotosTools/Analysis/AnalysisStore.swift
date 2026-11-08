import Foundation
import SQLite3
import SyncKit

/// Cache of photo analyses, so a rescan only looks at new or edited photos, plus the near
/// duplicates the user has decided to keep.
///
/// Safe to call from any thread.
final class AnalysisStore: @unchecked Sendable {
    static let shared = AnalysisStore()

    private let db: SQLiteDatabase

    private init() {
        db = SQLiteDatabase(path: AppDirectories.support.appendingPathComponent("analysis.sqlite").path, synchronous: .normal)
        db.executeScript("""
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
            """)
        // Columns added after the first release. Rows from before have version 1, so tools that
        // need the new columns re-analyze them.
        db.migrate(to: 1) {
            db.addColumn("face_count", definition: "INTEGER NOT NULL DEFAULT 0", to: "analyses")
            db.addColumn("face_area", definition: "REAL NOT NULL DEFAULT 0", to: "analyses")
            db.addColumn("person_area", definition: "REAL NOT NULL DEFAULT 0", to: "analyses")
            db.addColumn("version", definition: "INTEGER NOT NULL DEFAULT 1", to: "analyses")
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
            // In groups, since SQLite limits how many values one statement can take.
            for start in stride(from: 0, to: ids.count, by: 500) {
                let group = Array(ids[start..<min(start + 500, ids.count)])
                let marks = Array(repeating: "?", count: group.count).joined(separator: ", ")
                for row in query("SELECT \(Self.columns) FROM analyses WHERE id IN (\(marks))", group, analysis) {
                    result[row.assetID] = row
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
            _ = db.transaction {
                // In groups, since SQLite limits how many values one statement can take.
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let group = Array(ids[start..<min(start + 500, ids.count)])
                    let marks = Array(repeating: "?", count: group.count).joined(separator: ", ")
                    db.execute("DELETE FROM analyses WHERE id IN (\(marks))", group)
                    db.execute("DELETE FROM kept WHERE id IN (\(marks))", group)
                }
            }
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

    private func locked<T>(_ body: () -> T) -> T { db.locked(body) }

    private func execute(_ sql: String, _ args: [Any?] = []) { db.execute(sql, args) }

    private func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (OpaquePointer) -> T) -> [T] { db.query(sql, args, row) }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? { SQLiteDatabase.text(stmt, column) }

    private func double(_ stmt: OpaquePointer, _ column: Int32) -> Double? { SQLiteDatabase.double(stmt, column) }

    private func floats(_ stmt: OpaquePointer, _ column: Int32) -> [Float] {
        guard let data = SQLiteDatabase.blob(stmt, column) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
