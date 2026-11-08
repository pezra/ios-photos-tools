import XCTest
@testable import SyncKit

final class DebouncedWriterTests: XCTestCase {
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        private var threads: [Bool] = []
        func add(_ value: Int) { lock.withLock { values.append(value); threads.append(Thread.isMainThread) } }
        var all: [Int] { lock.withLock { values } }
        var anyOnMain: Bool { lock.withLock { threads.contains(true) } }
    }

    func testABurstIsOneWriteOfTheLatestValue() async throws {
        let written = Written()
        let writer = DebouncedWriter<Int>(delay: 0.1) { written.add($0) }
        for i in 1...50 { writer.submit(i) }
        XCTAssertEqual(written.all, [])
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(written.all, [50])
    }

    func testChangesAfterAWriteAreWrittenAgain() async throws {
        let written = Written()
        let writer = DebouncedWriter<Int>(delay: 0.05) { written.add($0) }
        writer.submit(1)
        try await Task.sleep(for: .milliseconds(300))
        writer.submit(2)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(written.all, [1, 2])
    }

    func testFlushWritesWhatIsWaitingAtOnceAndOnlyOnce() async throws {
        let written = Written()
        let writer = DebouncedWriter<Int>(delay: 10) { written.add($0) }
        writer.submit(1)
        writer.submit(2)
        await Task.detached { writer.flush() }.value
        XCTAssertEqual(written.all, [2])
        // Nothing left for the timer or another flush.
        await Task.detached { writer.flush() }.value
        XCTAssertEqual(written.all, [2])
    }

    func testSubmitAfterFlushSchedulesANewWrite() async throws {
        let written = Written()
        let writer = DebouncedWriter<Int>(delay: 0.05) { written.add($0) }
        writer.submit(1)
        await Task.detached { writer.flush() }.value
        writer.submit(2)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(written.all, [1, 2])
    }

    func testWritesDoNotRunOnTheCallingThread() async throws {
        let written = Written()
        let writer = DebouncedWriter<Int>(delay: 0.01) { written.add($0) }
        await MainActor.run { writer.submit(1) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(written.all, [1])
        XCTAssertFalse(written.anyOnMain)
    }
}
