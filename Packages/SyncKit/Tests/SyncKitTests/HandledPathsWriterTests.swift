import XCTest
@testable import SyncKit

final class HandledPathsWriterTests: XCTestCase {
    private var dir: URL!
    private var store: BackupStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(path: dir.appendingPathComponent("backup.sqlite").path) {}
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: dir)
    }

    /// Where the file is written, standing in for the drive or the bucket.
    private actor Destination {
        var contents: [Data] = []
        var writing = 0
        var overlapped = false

        func put(_ data: Data, slowly: Bool) async {
            writing += 1
            if writing > 1 { overlapped = true }
            if slowly { try? await Task.sleep(for: .milliseconds(200)) }
            contents.append(data)
            writing -= 1
        }
    }

    private func claim(_ path: String) {
        XCTAssertTrue(store.claim([ResourceRow(id: path, assetID: path, path: path, s3Key: path)]))
    }

    func testOverlappingWritesLandInOrder() async throws {
        let writer = HandledPathsWriter(store: store, key: "written-test")
        let destination = Destination()
        claim("2026/A.HEIC")

        // The first write is slow, and the paths change while it's going.
        async let first = writer.write(force: true, interval: 500) { await destination.put($0, slowly: true) }
        try await Task.sleep(for: .milliseconds(50))
        claim("2026/B.HEIC")
        let second = try await writer.write(force: true, interval: 500) { await destination.put($0, slowly: false) }
        _ = try await first

        let overlapped = await destination.overlapped
        XCTAssertFalse(overlapped)
        let contents = await destination.contents
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(HandledPathsFile.decode(contents.last!).map(\.path), ["2026/A.HEIC", "2026/B.HEIC"])
        XCTAssertEqual(second, store.handledVersion)
        XCTAssertEqual(store.meta("written-test"), String(store.handledVersion), "the version of what was written last")
    }

    func testWritesOnlyWhenDue() async throws {
        let writer = HandledPathsWriter(store: store, key: "written-test")
        let destination = Destination()
        claim("2026/A.HEIC")
        let written = try await writer.write(force: true, interval: 500) { await destination.put($0, slowly: false) }
        XCTAssertEqual(written, store.handledVersion)
        let again = try await writer.write(force: true, interval: 500) { await destination.put($0, slowly: false) }
        XCTAssertNil(again, "nothing changed")
        claim("2026/B.HEIC")
        let notYet = try await writer.write(force: false, interval: 2) { await destination.put($0, slowly: false) }
        XCTAssertNil(notYet, "not enough changes")
        claim("2026/C.HEIC")
        let due = try await writer.write(force: false, interval: 2) { await destination.put($0, slowly: false) }
        XCTAssertEqual(due, store.handledVersion)
    }

    func testFailedWriteRecordsNothing() async {
        let writer = HandledPathsWriter(store: store, key: "written-test")
        claim("2026/A.HEIC")
        do {
            _ = try await writer.write(force: true, interval: 500) { _ in throw CocoaError(.fileWriteUnknown) }
            XCTFail("should throw")
        } catch {}
        XCTAssertNil(store.meta("written-test"))
    }

    func testOneWriterPerPlace() {
        XCTAssertTrue(HandledPathsWriter.shared(store: store, key: "a") === HandledPathsWriter.shared(store: store, key: "a"))
        XCTAssertFalse(HandledPathsWriter.shared(store: store, key: "a") === HandledPathsWriter.shared(store: store, key: "b"))
    }
}
