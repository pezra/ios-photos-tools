import XCTest
@testable import SyncKit

final class PassStatusTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: UUID().uuidString)
    }

    private func status() -> PassStatus {
        PassStatus(lastFinishedKey: "finished", defaults: defaults)
    }

    func testStartingAPassClearsTheOldError() {
        var s = status()
        s.report(phase: "Couldn't list the bucket", running: false, error: "boom")
        XCTAssertEqual(s.lastError, "boom")
        s.report(phase: "Checking library…", running: true, startingPass: true)
        XCTAssertNil(s.lastError)
        XCTAssertTrue(s.isRunning)
    }

    func testAnErrorMidPassIsKept() {
        var s = status()
        s.report(phase: "Copying", running: true, error: "one")
        s.report(phase: "Copying", running: true)
        XCTAssertEqual(s.lastError, "one")
    }

    func testFinishingReplacesTheErrorAndRecordsTheTime() {
        var s = status()
        let when = Date(timeIntervalSince1970: 1000)
        s.report(phase: "Copying", running: true, error: "one")
        s.report(phase: "Up to date", running: false, finished: true, at: when)
        XCTAssertNil(s.lastError)
        XCTAssertEqual(s.lastFinished, when)
        XCTAssertFalse(s.isRunning)
    }

    func testAPausedPassKeepsTheLastFinishedTime() {
        var s = status()
        let when = Date(timeIntervalSince1970: 1000)
        s.report(phase: "Up to date", running: false, finished: true, at: when)
        s.report(phase: "Paused", running: false)
        XCTAssertEqual(s.lastFinished, when)
    }

    func testLastFinishedIsKeptUnderItsKey() {
        var s = status()
        let when = Date(timeIntervalSince1970: 2000)
        s.report(phase: "Up to date", running: false, finished: true, at: when)
        XCTAssertEqual(status().lastFinished, when)
        XCTAssertNil(PassStatus(lastFinishedKey: "other", defaults: defaults).lastFinished)
    }
}
