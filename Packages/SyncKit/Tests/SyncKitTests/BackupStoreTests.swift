import SQLite3
import XCTest
@testable import SyncKit

final class BackupStoreTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("backup.sqlite").path }
    private var store: BackupStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: dir)
    }

    private func open() {
        store = BackupStore(path: path) {}
    }

    /// Runs SQL on its own connection, to set up what the store can't do through its own methods.
    private func sql(_ statements: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, statements, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
    }

    private func row(_ id: String, _ asset: String, _ path: String) -> ResourceRow {
        ResourceRow(id: id, assetID: asset, path: path, s3Key: path)
    }

    /// Claims and registers files for an asset.
    private func add(_ rows: [ResourceRow], asset: String) {
        XCTAssertTrue(store.claim(rows))
        store.register(rows, assetID: asset, assetModifiedAt: 5)
    }

    private func upload(_ ids: String...) {
        for id in ids { store.markUploading(id, stagedName: "staged-\(id)", sha256: nil) }
    }

    private func state(_ asset: String, _ id: String) -> ResourceState? {
        store.resources(forAsset: asset)[id]?.state
    }

    // MARK: - Uploading

    func testFinishedUploadIsDoneAndKnownToBeInTheBucket() {
        open()
        add([row("a#1", "a", "2026/A.HEIC"), row("a#9", "a", "2026/A.MOV")], asset: "a")
        upload("a#1", "a#9")
        XCTAssertFalse(store.isInBucket("2026/A.HEIC"))
        XCTAssertFalse(store.resetIfSuperseded("a#1"))
        store.markDone("a#1")
        XCTAssertNil(store.completedAssets()["a"])
        store.markDone("a#9")
        XCTAssertTrue(store.isInBucket("2026/A.HEIC"))
        XCTAssertTrue(store.isInBucket("2026/A.MOV"))
        XCTAssertNotNil(store.completedAssets()["a"])
    }

    // MARK: - Taking a new name during an upload

    func testUploadToAnOldNameIsSentAgainToTheNewOne() {
        open()
        add([row("b#1", "b", "2026/B.HEIC"), row("b#9", "b", "2026/B.MOV")], asset: "b")
        upload("b#1", "b#9")

        store.retirePaths(forResource: "b#1")
        XCTAssertEqual(state("b", "b#1"), .pending)
        XCTAssertEqual(state("b", "b#9"), .uploading)

        store.markDone("b#9")
        XCTAssertEqual(state("b", "b#9"), .pending, "finished at the old name, so not done")
        XCTAssertNil(store.completedAssets()["b"])
        XCTAssertFalse(store.isInBucket("2026/B.MOV"))

        XCTAssertTrue(store.claim([row("b#1", "b", "2026/B (1).HEIC"), row("b#9", "b", "2026/B (1).MOV")]))
        upload("b#1", "b#9")
        store.markDone("b#1")
        store.markDone("b#9")
        XCTAssertTrue(store.isInBucket("2026/B (1).HEIC"))
        XCTAssertTrue(store.isInBucket("2026/B (1).MOV"))
        XCTAssertNotNil(store.completedAssets()["b"])
    }

    func testRefusalFromAnOldNameLeavesTheNewNameAlone() {
        open()
        add([row("c#9", "c", "2026/C.MOV")], asset: "c")
        upload("c#9")
        store.retirePaths(forAsset: "c")
        XCTAssertTrue(store.claim([row("c#9", "c", "2026/C (1).MOV")]))

        XCTAssertTrue(store.resetIfSuperseded("c#9"))
        XCTAssertEqual(store.paths(forAsset: "c")["c#9"], "2026/C (1).MOV")
        XCTAssertEqual(state("c", "c#9"), .pending)
        XCTAssertFalse(store.resetIfSuperseded("c#9"), "only once")
    }

    func testVanishedUploadCanBeRetried() {
        open()
        let d = [row("d#1", "d", "2026/D.HEIC")]
        add(d, asset: "d")
        upload("d#1")
        store.retirePaths(forAsset: "d")
        store.resetToPending("d#1")
        XCTAssertTrue(store.claim(d))
        upload("d#1")
        store.markDone("d#1")
        XCTAssertEqual(state("d", "d#1"), .done)
    }

    // MARK: - Paths

    func testPathHolders() {
        open()
        XCTAssertEqual(store.pathHolder("2026/E.HEIC"), .free)
        add([row("e#1", "e", "2026/E.HEIC")], asset: "e")
        XCTAssertEqual(store.pathHolder("2026/e.heic"), .resource("e#1"), "whatever the spelling")
        XCTAssertFalse(store.claim([row("x#1", "x", "2026/E.HEIC")]), "someone else's")
        store.retirePaths(forAsset: "e")
        XCTAssertEqual(store.pathHolder("2026/E.HEIC"), .released)
    }

    func testRetiredPathIsNoLongerKnownToBeThere() {
        open()
        add([row("e#1", "e", "2026/E.HEIC")], asset: "e")
        upload("e#1")
        store.markDone("e#1")
        store.markOnDrive("2026/E.HEIC")
        store.retirePaths(forAsset: "e")
        XCTAssertFalse(store.isInBucket("2026/E.HEIC"))
        XCTAssertFalse(store.isOnDrive("2026/E.HEIC"))
    }

    func testResourceIDStartsWithTheAsset() {
        XCTAssertEqual(ResourceRow.assetID(ofResource: "X/L0/001#1#a.HEIC"), "X/L0/001")
    }

    // MARK: - What each copy of the handled paths file can say

    func testAFileOnlySpeaksForWhereItWasFound() {
        open()
        let entry = { (path: String) in HandledPath(path: path, kind: .backup, onDrive: true, inBucket: true) }
        XCTAssertTrue(store.mergeHandled([entry("2026/S.HEIC")], from: .s3))
        XCTAssertTrue(store.isInBucket("2026/S.HEIC"))
        XCTAssertFalse(store.isOnDrive("2026/S.HEIC"))

        XCTAssertTrue(store.mergeHandled([entry("2026/T.HEIC")], from: .drive))
        XCTAssertFalse(store.isInBucket("2026/T.HEIC"))
        XCTAssertTrue(store.isOnDrive("2026/T.HEIC"))

        XCTAssertTrue(store.mergeHandled([entry("2026/S.HEIC")], from: .drive))
        XCTAssertTrue(store.isInBucket("2026/S.HEIC"), "a known path keeps what's known about it")
        XCTAssertTrue(store.isOnDrive("2026/S.HEIC"))
    }

    func testForgettingTheBucket() {
        open()
        add([row("a#1", "a", "2026/A.HEIC")], asset: "a")
        upload("a#1")
        store.markDone("a#1")
        store.forgetBucketContents()
        XCTAssertFalse(store.isInBucket("2026/A.HEIC"))
        store.markDone("a#1")
        XCTAssertTrue(store.isInBucket("2026/A.HEIC"))
        store.reset()
        XCTAssertFalse(store.isInBucket("2026/A.HEIC"))
        XCTAssertNil(store.completedAssets()["a"])
    }

    // MARK: - Files that are gone

    func testRevertedEditLetsItsPhotoComplete() {
        open()
        add([row("r#1", "r", "2026/R.HEIC"), row("r#e", "r", "2026/R-edited.jpg")], asset: "r")
        upload("r#1", "r#e")
        store.markDone("r#1")
        store.markFailed("r#e", error: "boom")
        store.markAssetCompleteIfFinished("r")
        XCTAssertNil(store.completedAssets()["r"], "stuck")
        XCTAssertEqual(store.count(.failed), 1)

        store.forgetMissingResources(forAsset: "r", keeping: ["r#1"])
        XCTAssertNil(state("r", "r#e"))
        XCTAssertEqual(state("r", "r#1"), .done)
        XCTAssertEqual(store.count(.failed), 0)
        store.markAssetCompleteIfFinished("r")
        XCTAssertEqual(store.completedAssets()["r"], 5)
    }

    func testForgettingFilesKeepsWhatMatters() {
        open()
        add(["k1", "k2", "k3", "k4"].map { row($0, "k", "2026/\($0).x") }, asset: "k")
        add([row("o1", "o", "2026/o1.x")], asset: "o")
        upload("k1", "k2")
        store.markDone("k1")
        store.forgetMissingResources(forAsset: "k", keeping: ["k4"])
        XCTAssertEqual(state("k", "k1"), .done)
        XCTAssertEqual(state("k", "k2"), .uploading)
        XCTAssertNil(state("k", "k3"))
        XCTAssertEqual(state("k", "k4"), .pending)
        store.forgetMissingResources(forAsset: "k", keeping: [])
        XCTAssertNil(state("k", "k4"))
        XCTAssertEqual(state("o", "o1"), .pending, "another asset")
    }

    func testPhotoLeavingTheLibraryStopsCountingAsFailed() {
        open()
        add(["g1", "g2", "g3", "g4"].map { row($0, "gone", "2026/\($0).x") }, asset: "gone")
        add([row("h1", "here", "2026/h1.x")], asset: "here")
        store.markFailed("g1", error: "boom")
        upload("g3", "g4")
        store.markDone("g4")
        store.setLibraryAssets(["here"])
        store.forgetResourcesOfMissingAssets()
        XCTAssertNil(state("gone", "g1"))
        XCTAssertNil(state("gone", "g2"))
        XCTAssertEqual(state("gone", "g3"), .uploading)
        XCTAssertEqual(state("gone", "g4"), .done)
        XCTAssertEqual(state("here", "h1"), .pending)
        XCTAssertEqual(store.count(.failed), 0)
    }

    // MARK: - Writes that fail

    /// Makes any write of a path or tag containing "boom" fail partway through a change.
    private func openWithFailures() {
        open()
        sql("""
            CREATE TRIGGER f1 BEFORE INSERT ON remote_files WHEN NEW.path LIKE 'boom%' BEGIN SELECT RAISE(ABORT, 'forced'); END;
            CREATE TRIGGER f2 BEFORE INSERT ON handled_paths WHEN NEW.path LIKE 'boom%' BEGIN SELECT RAISE(ABORT, 'forced'); END;
            CREATE TRIGGER f3 BEFORE INSERT ON imported_assets WHEN NEW.tag = 'boom' BEGIN SELECT RAISE(ABORT, 'forced'); END;
            """)
    }

    private func entry(_ path: String) -> InventoryEntry {
        InventoryEntry(source: .s3, path: path, size: 1)
    }

    func testFailedListingKeepsThePreviousOne() {
        openWithFailures()
        XCTAssertTrue(store.replaceInventory(source: .s3, entries: [entry("keep/a.jpg")]))
        XCTAssertFalse(store.replaceInventory(source: .s3, entries: [entry("new/x.jpg"), entry("boom/y.jpg"), entry("new/z.jpg")]))
        XCTAssertEqual(store.inventory().map(\.path), ["keep/a.jpg"])
    }

    func testFailedPartOfAListingKeepsWhatWasThere() {
        openWithFailures()
        XCTAssertTrue(store.addInventory(source: .s3, entries: [entry("2019/a.jpg")]))
        XCTAssertFalse(store.addInventory(source: .s3, entries: [entry("2019/b.jpg"), entry("boom/c.jpg")], replacingFolder: "2019"))
        XCTAssertEqual(store.inventory().map(\.path), ["2019/a.jpg"])
    }

    func testListingAFolderAgainOnlyForgetsWhatsDirectlyInIt() {
        open()
        XCTAssertTrue(store.addInventory(source: .s3, entries: [
            entry("top.jpg"), entry("2019/a.jpg"), entry("2019/trip/b.jpg"), entry("2019 x/c.jpg"), entry("2020/d.jpg"),
        ]))
        XCTAssertTrue(store.addInventory(source: .s3, entries: [entry("2019/e.jpg")], replacingFolder: "2019"))
        XCTAssertEqual(Set(store.inventory().map(\.path)), ["top.jpg", "2019/e.jpg", "2019/trip/b.jpg", "2019 x/c.jpg", "2020/d.jpg"])
        XCTAssertTrue(store.addInventory(source: .s3, entries: [], replacingFolder: ""))
        XCTAssertEqual(Set(store.inventory().map(\.path)), ["2019/e.jpg", "2019/trip/b.jpg", "2019 x/c.jpg", "2020/d.jpg"])
    }

    func testFinishedListingForgetsFoldersThatAreGone() {
        open()
        XCTAssertTrue(store.addInventory(source: .s3, entries: [entry("top.jpg"), entry("Ä/a.jpg"), entry("2019/trip/b.jpg"), entry("2020/c.jpg")]))
        XCTAssertTrue(store.addInventory(source: .drive, entries: [InventoryEntry(source: .drive, path: "2020/d.jpg", size: 1)]))
        XCTAssertTrue(store.keepInventory(source: .s3, onlyInFolders: ["", "ä", "2019"]))
        XCTAssertEqual(Set(store.inventory().map(\.path)), ["top.jpg", "Ä/a.jpg", "2020/d.jpg"])
    }

    func testFailedClaimChangesNothing() {
        openWithFailures()
        let version = store.handledVersion
        XCTAssertFalse(store.claim([row("f#1", "f", "ok/1.jpg"), row("f#2", "f", "boom/2.jpg"), row("f#3", "f", "ok/3.jpg")]))
        XCTAssertEqual(store.pathHolder("ok/1.jpg"), .free)
        XCTAssertEqual(store.pathHolder("ok/3.jpg"), .free)
        XCTAssertEqual(store.handledVersion, version)
    }

    func testFailedMergeAndImportsKeepNothing() {
        openWithFailures()
        let version = store.handledVersion
        XCTAssertFalse(store.mergeHandled([HandledPath(path: "ok/m.jpg", kind: .backup), HandledPath(path: "boom/m.jpg", kind: .backup)], from: .s3))
        XCTAssertEqual(store.pathHolder("ok/m.jpg"), .free)
        XCTAssertFalse(store.markImported(paths: ["ok/i.jpg", "boom/i.jpg"]))
        XCTAssertEqual(store.pathHolder("ok/i.jpg"), .free)
        XCTAssertFalse(store.recordImports([(assetID: "a4", path: "ok/r.jpg"), (assetID: "a5", path: "boom/r.jpg")]))
        XCTAssertFalse(store.importedAssetIDs().contains("a4"))
        XCTAssertEqual(store.pathHolder("ok/r.jpg"), .free)
        XCTAssertEqual(store.handledVersion, version)
    }

    func testFailedReplaceKeepsTheOldRecordOfImports() {
        openWithFailures()
        XCTAssertTrue(store.replaceImportedAssets([(assetID: "a1", tag: "t1")]))
        XCTAssertFalse(store.replaceImportedAssets([(assetID: "a2", tag: "t2"), (assetID: "a3", tag: "boom")]))
        XCTAssertEqual(store.importedTags(), ["t1"])
    }

    func testStatementThatCantBePreparedAlsoUndoesTheChange() {
        open()
        let version = store.handledVersion
        sql("DROP TABLE handled_paths")
        XCTAssertFalse(store.recordImports([(assetID: "a1", path: "ok/r.jpg")]))
        XCTAssertFalse(store.importedAssetIDs().contains("a1"), "written before the statement that failed")
        XCTAssertEqual(store.handledVersion, version)
    }

    func testStoreWorksNormallyAfterAFailure() {
        openWithFailures()
        XCTAssertFalse(store.claim([row("f#2", "f", "boom/2.jpg")]))
        let version = store.handledVersion
        XCTAssertTrue(store.claim([row("f#1", "f", "ok/1.jpg")]))
        XCTAssertEqual(store.handledVersion, version + 1)
        store.setMeta("after", "1")
        XCTAssertEqual(store.meta("after"), "1")
        XCTAssertTrue(store.mergeHandled([], from: .s3))
        XCTAssertTrue(store.recordImports([]))
        XCTAssertTrue(store.markImported(paths: []))
        XCTAssertEqual(store.handledVersion, version + 1, "empty changes don't count")
    }

    // MARK: - Migrations

    private func seed(version: Int) {
        sql("""
            CREATE TABLE handled_paths (norm TEXT PRIMARY KEY, path TEXT NOT NULL, kind TEXT NOT NULL, resource_id TEXT, asset_id TEXT, on_drive INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE resources (id TEXT PRIMARY KEY, asset_id TEXT NOT NULL, s3_key TEXT NOT NULL, state INTEGER NOT NULL, staged_name TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, updated_at REAL NOT NULL, sha256 TEXT, asset_modified_at REAL);
            INSERT INTO resources (id, asset_id, s3_key, state, updated_at) VALUES ('done', 'x', 'k', 2, 0), ('pending', 'y', 'k', 0, 0);
            INSERT INTO handled_paths (norm, path, kind, resource_id, asset_id) VALUES ('2026/done.heic', '2026/done.heic', 'backup', 'done', 'x'), ('2026/pending.heic', '2026/pending.heic', 'backup', 'pending', 'y');
            PRAGMA user_version = \(version);
            """)
    }

    func testUploadedFilesCountAsInTheBucketAfterUpgrading() {
        seed(version: 1)
        var layoutChanged = false
        store = BackupStore(path: path) { layoutChanged = true }
        XCTAssertFalse(layoutChanged)
        XCTAssertTrue(store.isInBucket("2026/done.heic"))
        XCTAssertFalse(store.isInBucket("2026/pending.heic"))
        XCTAssertEqual(store.count(.done), 1)
        XCTAssertEqual(store.count(.pending), 1)
        upload("pending")
        store.markDone("pending")
        XCTAssertEqual(store.count(.done), 2, "older rows work with the newer columns")
    }

    func testOldLayoutStartsOverOnce() {
        seed(version: 0)
        var changes = 0
        store = BackupStore(path: path) { changes += 1 }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(store.count(.done), 0)
        store = BackupStore(path: path) { changes += 1 }
        XCTAssertEqual(changes, 1)
    }

    // MARK: - Coverage

    func testCoverageIsUnknownUntilTheLibraryIsListed() {
        open()
        XCTAssertNil(store.coverage(driveID: nil))
        store.setLibraryAssets(["a", "b", "c"])
        store.markAssetComplete("a", modifiedAt: 1)
        store.markAssetComplete("gone", modifiedAt: 1)
        store.markDriveAssetComplete("a", driveID: "d", modifiedAt: 1)
        store.markDriveAssetComplete("b", driveID: "d", modifiedAt: 1)
        let coverage = store.coverage(driveID: "d")
        XCTAssertEqual(coverage, BackupStore.Coverage(total: 3, cloud: 1, drive: 2, both: 1))
        XCTAssertEqual(coverage?.driveOnly, 1)
        XCTAssertEqual(coverage?.nowhere, 1)
    }
}
