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
        async let first = writer.write(force: true) { await destination.put($0, slowly: true) }
        try await Task.sleep(for: .milliseconds(50))
        claim("2026/B.HEIC")
        let second = try await writer.write(force: true) { await destination.put($0, slowly: false) }
        _ = try await first

        let overlapped = await destination.overlapped
        XCTAssertFalse(overlapped)
        let contents = await destination.contents
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(HandledPathsFile.decode(contents.last!).map(\.path), ["2026/A.HEIC", "2026/B.HEIC"])
        XCTAssertEqual(second, store.handledVersion)
        XCTAssertEqual(store.meta("written-test"), String(store.handledVersion), "the version of what was written last")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    func testTimeRule() async throws {
        let clock = Clock()
        let writer = HandledPathsWriter(store: store, key: "written-test") { clock.now }
        let destination = Destination()
        func put(force: Bool) async throws -> Int? {
            try await writer.write(force: force) { await destination.put($0, slowly: false) }
        }
        claim("2026/A.HEIC")
        let first = try await put(force: false)
        XCTAssertEqual(first, store.handledVersion, "nothing written yet here, so the first change is due")

        let unchanged = try await put(force: false)
        XCTAssertNil(unchanged)
        clock.advance(600)
        let unchangedLater = try await put(force: false)
        XCTAssertNil(unchangedLater, "nothing changed, however long it's been")
        let forcedUnchanged = try await put(force: true)
        XCTAssertNil(forcedUnchanged, "forcing doesn't write what's already there")

        claim("2026/B.HEIC")
        let late = try await put(force: false)
        XCTAssertEqual(late, store.handledVersion, "changed, and 10 minutes since the last write")

        claim("2026/C.HEIC")
        let early = try await put(force: false)
        XCTAssertNil(early, "changed, but just written")
        clock.advance(299)
        let almost = try await put(force: false)
        XCTAssertNil(almost)
        clock.advance(1)
        let due = try await put(force: false)
        XCTAssertEqual(due, store.handledVersion, "5 minutes since the last write")

        claim("2026/D.HEIC")
        let forced = try await put(force: true)
        XCTAssertEqual(forced, store.handledVersion, "forcing writes a change at once")
        let count = await destination.contents.count
        XCTAssertEqual(count, 4)
    }

    func testTimeIsKeptPerDestination() async throws {
        let clock = Clock()
        let one = HandledPathsWriter(store: store, key: "written-one") { clock.now }
        let two = HandledPathsWriter(store: store, key: "written-two") { clock.now }
        claim("2026/A.HEIC")
        _ = try await one.write(force: false) { _ in }
        claim("2026/B.HEIC")
        let other = try await two.write(force: false) { _ in }
        XCTAssertNotNil(other, "the other place hasn't been written")
        let same = try await one.write(force: false) { _ in }
        XCTAssertNil(same)
    }

    func testIsDue() {
        typealias W = HandledPathsWriter
        XCTAssertFalse(W.isDue(force: true, changed: false, sinceLastWrite: 1000))
        XCTAssertTrue(W.isDue(force: true, changed: true, sinceLastWrite: 0))
        XCTAssertFalse(W.isDue(force: false, changed: true, sinceLastWrite: 299))
        XCTAssertTrue(W.isDue(force: false, changed: true, sinceLastWrite: 300))
        XCTAssertTrue(W.isDue(force: false, changed: true, sinceLastWrite: nil))
    }

    func testFailedWriteRecordsNothing() async {
        let writer = HandledPathsWriter(store: store, key: "written-test")
        claim("2026/A.HEIC")
        do {
            _ = try await writer.write(force: true) { _ in throw CocoaError(.fileWriteUnknown) }
            XCTFail("should throw")
        } catch {}
        XCTAssertNil(store.meta("written-test"))
    }

    func testOneWriterPerPlace() {
        XCTAssertTrue(HandledPathsWriter.shared(store: store, key: "a") === HandledPathsWriter.shared(store: store, key: "a"))
        XCTAssertFalse(HandledPathsWriter.shared(store: store, key: "a") === HandledPathsWriter.shared(store: store, key: "b"))
    }
}
