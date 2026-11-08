import XCTest
@testable import SyncKit

final class UploadEventsTests: XCTestCase {
    /// A count of uploads in flight, as the store would give it.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ value: Int) { self.value = value }
        var count: Int {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    // MARK: - ChangeSignal

    func testWaitReturnsStraightAwayForASignalAlreadySent() async {
        let signal = ChangeSignal()
        let seen = signal.current
        signal.send()
        let signalled = await signal.wait(since: seen, timeout: .seconds(10))
        XCTAssertTrue(signalled)
    }

    func testEverySignalWakesEveryListener() async {
        let signal = ChangeSignal()
        let seen = signal.current
        let listeners = (0..<3).map { _ in Task { await signal.wait(since: seen, timeout: .seconds(10)) } }
        try? await Task.sleep(for: .milliseconds(50))
        signal.send()
        for listener in listeners {
            let signalled = await listener.value
            XCTAssertTrue(signalled)
        }
    }

    func testWaitTimesOutWithNoSignal() async {
        let signal = ChangeSignal()
        let signalled = await signal.wait(since: signal.current, timeout: .milliseconds(20))
        XCTAssertFalse(signalled)
    }

    func testCancellingEndsTheWait() async {
        let signal = ChangeSignal()
        let listener = Task { await signal.wait(since: signal.current, timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(20))
        listener.cancel()
        let signalled = await listener.value
        XCTAssertFalse(signalled)
    }

    func testWaitingForRoomWakesWhenAnUploadFinishes() async {
        let signal = ChangeSignal()
        let uploading = Counter(8)
        let waiter = Task { await signal.wait(until: { uploading.count < 8 }, stallLimit: .seconds(10)) }
        try? await Task.sleep(for: .milliseconds(20))
        signal.send()
        try? await Task.sleep(for: .milliseconds(20))
        uploading.count = 7
        signal.send()
        let room = await waiter.value
        XCTAssertTrue(room)
    }

    func testWaitingForRoomGivesUpWhenNothingFinishes() async {
        let signal = ChangeSignal()
        let room = await signal.wait(until: { false }, stallLimit: .milliseconds(20))
        XCTAssertFalse(room)
    }

    func testWaitingForRoomNoticesAChangeWhoseSignalWasMissed() async {
        let signal = ChangeSignal()
        let uploading = Counter(8)
        let waiter = Task { await signal.wait(until: { uploading.count < 8 }, stallLimit: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(10))
        uploading.count = 0
        let room = await waiter.value
        XCTAssertTrue(room)
    }

    // MARK: - SettleTracker

    func testSettlesWhenTheLastUploadFinishes() async {
        let signal = ChangeSignal()
        let uploading = Counter(2)
        let tracker = SettleTracker(signal: signal) { uploading.count }
        let settled = Task { await tracker.nextSettle() }
        try? await Task.sleep(for: .milliseconds(20))
        uploading.count = 1
        signal.send()
        try? await Task.sleep(for: .milliseconds(20))
        uploading.count = 0
        signal.send()
        let didSettle = await settled.value
        XCTAssertTrue(didSettle)
    }

    func testSignalsBeforeAnyoneListensStillSettle() async {
        let signal = ChangeSignal()
        let uploading = Counter(3)
        signal.send()
        uploading.count = 0
        signal.send()
        let tracker = SettleTracker(signal: signal) { uploading.count }
        let didSettle = await tracker.nextSettle(recheckEvery: .seconds(30))
        XCTAssertTrue(didSettle, "the count is read when listening starts")
    }

    func testDuplicateSignalsSettleOnce() async {
        let signal = ChangeSignal()
        let uploading = Counter(0)
        let tracker = SettleTracker(signal: signal) { uploading.count }
        XCTAssertTrue(tracker.check())
        signal.send()
        signal.send()
        XCTAssertFalse(tracker.check())
        XCTAssertFalse(tracker.check())

        uploading.count = 1
        signal.send()
        XCTAssertFalse(tracker.check())
        uploading.count = 0
        signal.send()
        signal.send()
        XCTAssertTrue(tracker.check())
        XCTAssertFalse(tracker.check())
    }

    func testNoSettleWhileWaitingForTheNextUpload() async {
        let signal = ChangeSignal()
        let uploading = Counter(0)
        let tracker = SettleTracker(signal: signal) { uploading.count }
        XCTAssertTrue(tracker.check())
        let settled = Task { await tracker.nextSettle(recheckEvery: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(60))
        signal.send()
        try? await Task.sleep(for: .milliseconds(20))
        settled.cancel()
        let didSettle = await settled.value
        XCTAssertFalse(didSettle, "nothing was uploaded since the last settle")
    }

    func testResetMidFlightSettlesOnceTheUploadsComeBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try! BackupStore(path: dir.appendingPathComponent("backup.sqlite").path) {}
        let rows = ["2026/A.HEIC", "2026/A.MOV"].enumerated().map { index, path in
            ResourceRow(id: "a#\(index)", assetID: "a", path: path, s3Key: path)
        }
        XCTAssertTrue(store.claim(rows))
        store.register(rows, assetID: "a", assetModifiedAt: 5)
        for row in rows {
            XCTAssertTrue(store.markUploading(row.id, path: row.path, bucket: "svc/A/p", stagedName: "s-\(row.id)", sha256: nil))
        }
        let signal = ChangeSignal()
        let tracker = SettleTracker(signal: signal) { store.count(.uploading) }
        XCTAssertFalse(tracker.check())

        // "Forget backup history" while they're going: they can't be stopped, so they still count.
        store.reset()
        signal.send()
        XCTAssertFalse(tracker.check())

        XCTAssertTrue(store.resetIfSuperseded("a#0"))
        signal.send()
        XCTAssertFalse(tracker.check())
        XCTAssertTrue(store.resetIfSuperseded("a#1"))
        signal.send()
        XCTAssertTrue(tracker.check())
        XCTAssertEqual(store.count(.pending), 2, "to be sent again")
        XCTAssertNil(store.completedAssets()["a"])
    }

    // MARK: - StagingBudget

    func testForegroundWaitsForASlot() {
        XCTAssertEqual(StagingBudget.room(background: false, uploading: 7, stagedBytes: 0, availableBytes: nil), .room)
        XCTAssertEqual(StagingBudget.room(background: false, uploading: 8, stagedBytes: 0, availableBytes: nil), .waitForSlot)
    }

    func testBackgroundStagesToTheBudgetWithoutWaitingForSlots() {
        let gb: Int64 = 1 << 30
        XCTAssertEqual(StagingBudget.room(background: true, uploading: 500, stagedBytes: gb, availableBytes: 50 * gb), .room)
        XCTAssertEqual(StagingBudget.room(background: true, uploading: 1, stagedBytes: 2 * gb, availableBytes: 50 * gb), .full)
        XCTAssertEqual(StagingBudget.room(background: true, uploading: 1, stagedBytes: 0, availableBytes: gb / 2), .full, "the disk is nearly full")
        XCTAssertEqual(StagingBudget.room(background: true, uploading: 1, stagedBytes: 0, availableBytes: nil), .room)
    }
}
