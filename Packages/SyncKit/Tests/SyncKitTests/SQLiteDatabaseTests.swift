import SQLite3
import XCTest
@testable import SyncKit

final class SQLiteDatabaseTests: XCTestCase {
    private var dir: URL!
    private var db: SQLiteDatabase!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        db.executeScript("""
            CREATE TABLE t (id TEXT PRIMARY KEY, n REAL, b BLOB);
            CREATE TRIGGER boom BEFORE INSERT ON t WHEN NEW.id LIKE 'boom%' BEGIN SELECT RAISE(ABORT, 'forced'); END;
            """)
    }

    override func tearDownWithError() throws {
        db = nil
        try FileManager.default.removeItem(at: dir)
    }

    private func ids() -> [String] {
        db.query("SELECT id FROM t ORDER BY id") { SQLiteDatabase.text($0, 0) ?? "" }
    }

    func testAFileThatCantBeOpenedThrows() {
        // A file is in the way of the folder the database would go in.
        let blocked = dir.appendingPathComponent("blocked")
        FileManager.default.createFile(atPath: blocked.path, contents: Data())
        XCTAssertThrowsError(try SQLiteDatabase(path: blocked.appendingPathComponent("t.sqlite").path))
        XCTAssertThrowsError(try BackupStore(path: blocked.appendingPathComponent("backup.sqlite").path) {})
    }

    func testFailedStatementRollsBackTheTransaction() {
        let saved = db.transaction {
            db.execute("INSERT INTO t (id) VALUES (?)", ["a"])
            db.execute("INSERT INTO t (id) VALUES (?)", ["boom"])
            db.execute("INSERT INTO t (id) VALUES (?)", ["c"])
        }
        XCTAssertFalse(saved)
        XCTAssertEqual(ids(), [])
        XCTAssertTrue(db.transaction { db.execute("INSERT INTO t (id) VALUES (?)", ["d"]) }, "works again afterwards")
        XCTAssertEqual(ids(), ["d"])
    }

    func testThrowingBodyRollsBack() {
        struct Oops: Error {}
        XCTAssertFalse(db.transaction {
            db.execute("INSERT INTO t (id) VALUES (?)", ["a"])
            throw Oops()
        })
        XCTAssertEqual(ids(), [])
    }

    func testInsertStopsAtTheFirstFailure() {
        let saved = db.transaction {
            try db.insert("INSERT INTO t (id) VALUES (?)", rows: ["a", "boom", "c"]) { SQLiteDatabase.bind($0, 1, $1) }
        }
        XCTAssertFalse(saved)
        XCTAssertEqual(ids(), [])
        // Outside a transaction what came before stays, and nothing after it is tried.
        XCTAssertThrowsError(try db.insert("INSERT INTO t (id) VALUES (?)", rows: ["a", "boom", "c"]) { SQLiteDatabase.bind($0, 1, $1) })
        XCTAssertEqual(ids(), ["a"])
    }

    func testNullableReads() {
        db.execute("INSERT INTO t (id, n) VALUES (?, ?)", ["null", nil])
        db.execute("INSERT INTO t (id, n) VALUES (?, ?)", ["zero", 0.0])
        db.execute("INSERT INTO t (id, n) VALUES (?, ?)", ["two", 2.5])
        let values = db.query("SELECT id, n, b FROM t ORDER BY id") { (SQLiteDatabase.text($0, 0), SQLiteDatabase.double($0, 1), SQLiteDatabase.blob($0, 2)) }
        XCTAssertEqual(values.map(\.0), ["null", "two", "zero"])
        XCTAssertEqual(values.map { $0.1 }, [nil, 2.5, 0.0])
        XCTAssertTrue(values.allSatisfy { $0.2 == nil })
    }

    func testBlobRoundTrip() {
        let data = Data([0, 1, 2, 255, 0, 7])
        db.execute("INSERT INTO t (id, b) VALUES (?, ?)", ["a", data])
        XCTAssertEqual(db.query("SELECT b FROM t") { SQLiteDatabase.blob($0, 0) }, [data])
        XCTAssertEqual(db.changes, 1)
    }

    func testMigrationBumpsTheVersionOnlyOnSuccess() {
        XCTAssertEqual(db.userVersion, 0)
        XCTAssertTrue(db.migrate(to: 1) { db.execute("INSERT INTO t (id) VALUES (?)", ["a"]) })
        XCTAssertEqual(db.userVersion, 1)
        XCTAssertTrue(db.migrate(to: 1) { db.execute("INSERT INTO t (id) VALUES (?)", ["again"]) }, "already done")
        XCTAssertEqual(ids(), ["a"])
    }

    func testFailedMigrationLeavesTheVersionAndDataAlone() {
        XCTAssertFalse(db.migrate(to: 1) {
            db.execute("INSERT INTO t (id) VALUES (?)", ["a"])
            db.execute("INSERT INTO t (id) VALUES (?)", ["boom"])
        })
        XCTAssertEqual(db.userVersion, 0)
        XCTAssertEqual(ids(), [])
        XCTAssertFalse(db.migrate(to: 2) {
            db.execute("ALTER TABLE t ADD COLUMN extra TEXT")
            throw SQLiteDatabase.StatementFailure(message: "no")
        })
        XCTAssertEqual(db.userVersion, 0)
        XCTAssertEqual(db.query("PRAGMA table_info(t)") { SQLiteDatabase.text($0, 1) }.count, 3, "the new column went with it")
    }

    func testAddColumnSkipsOneThatExists() {
        db.addColumn("n", definition: "REAL", to: "t")
        db.addColumn("extra", definition: "TEXT", to: "t")
        XCTAssertEqual(db.query("PRAGMA table_info(t)") { SQLiteDatabase.text($0, 1) }, ["id", "n", "b", "extra"])
    }
}
