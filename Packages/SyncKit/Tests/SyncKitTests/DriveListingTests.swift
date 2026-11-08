import XCTest
@testable import SyncKit

final class DriveListingTests: XCTestCase {
    private var dir: URL!
    private var drive: URL { dir.appendingPathComponent("drive") }
    private var store: BackupStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        store = BackupStore(path: dir.appendingPathComponent("backup.sqlite").path) {}
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: dir)
    }

    private func write(_ paths: String...) throws {
        for path in paths {
            let url = drive.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private func listing(batchSize: Int = 2) -> DriveListing {
        DriveListing(store: store, root: drive, key: "listing", batchSize: batchSize)
    }

    private var listed: Set<String> { Set(store.inventory().map(\.path)) }

    func testListsLibraryFilesInEveryFolder() async throws {
        try write("top.jpg", "2019/a.jpg", "2019/trip/b.jpg", ".photos-tools/handled-paths.jsonl", "2020/._c.jpg", "2020/c.jpg")
        try await listing().run(freshFor: 0)
        XCTAssertEqual(listed, ["top.jpg", "2019/a.jpg", "2019/trip/b.jpg", "2020/c.jpg"])
    }

    func testListingCutShortCarriesOnFromWhereItGot() async throws {
        try write("2019/a.jpg", "2019/b.jpg", "2019/c.jpg", "2019/d.jpg", "2019/e.jpg", "2020/f.jpg")
        // The top folder fills the first batch, then 2019 is part way through the second.
        let first = Task {
            try await listing().run(freshFor: 0) { found in
                if found > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            try await first.value
            XCTFail("Expected the listing to stop")
        } catch is CancellationError {}
        XCTAssertEqual(listed, ["2019/a.jpg", "2019/b.jpg"])

        // Files before the place it got to aren't read again.
        try FileManager.default.removeItem(at: drive.appendingPathComponent("2019/a.jpg"))
        var reports: [Int] = []
        try await listing().run(freshFor: 0) { reports.append($0) }
        XCTAssertEqual(reports.first, 4)
        XCTAssertEqual(listed, ["2019/a.jpg", "2019/b.jpg", "2019/c.jpg", "2019/d.jpg", "2019/e.jpg", "2020/f.jpg"])
    }

    func testProgressIsReportedBetweenSaves() async throws {
        try write("2019/a.jpg", "2019/b.jpg", "2019/c.jpg", "2019/d.jpg")
        var reports: [Int] = []
        try await DriveListing(store: store, root: drive, key: "listing", batchSize: 500, reportEvery: 2)
            .run(freshFor: 0) { reports.append($0) }
        XCTAssertEqual(reports, [0, 2, 4, 4])
    }

    func testFinishedListingForgetsWhatsGone() async throws {
        try write("top.jpg", "2019/a.jpg", "2019/b.jpg", "2020/c.jpg")
        try await listing().run(freshFor: 0)
        try FileManager.default.removeItem(at: drive.appendingPathComponent("2019/b.jpg"))
        try FileManager.default.removeItem(at: drive.appendingPathComponent("2020"))
        try FileManager.default.removeItem(at: drive.appendingPathComponent("top.jpg"))
        try await listing().run(freshFor: 0)
        XCTAssertEqual(listed, ["2019/a.jpg"])
    }

    func testRecentListingIsntRepeated() async throws {
        try write("2019/a.jpg")
        try await listing().run(freshFor: 600)
        try write("2019/b.jpg")
        try await listing().run(freshFor: 600)
        XCTAssertEqual(listed, ["2019/a.jpg"])
        try await listing().run(freshFor: 0)
        XCTAssertEqual(listed, ["2019/a.jpg", "2019/b.jpg"])
    }

    func testUnpluggedDriveIsntTakenForEmpty() async throws {
        try write("2019/a.jpg")
        try await listing().run(freshFor: 0)
        try FileManager.default.removeItem(at: drive)
        do {
            try await listing().run(freshFor: 0)
            XCTFail("Expected the listing to fail")
        } catch {}
        XCTAssertEqual(listed, ["2019/a.jpg"])
    }
}
