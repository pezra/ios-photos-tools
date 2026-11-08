import XCTest
@testable import SyncKit

final class PassRunnerTests: XCTestCase {
    /// Counts and releases passes, so a test decides when each one ends.
    private actor Gate {
        var started = 0
        var ended = 0
        var cancelled = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false

        func pass() async {
            started += 1
            if !open { await withCheckedContinuation { waiters.append($0) } }
        }
        /// Like `pass`, but gives up when cancelled.
        func hold() async {
            started += 1
            while !open && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
        func noteEnd(cancelled wasCancelled: Bool) {
            ended += 1
            if wasCancelled { cancelled += 1 }
        }
    }

    /// A pass that stays until cancelled or released.
    private func waitingBody(_ gate: Gate) -> @Sendable () async -> Void {
        { await gate.pass() }
    }

    private func eventually(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out")
    }

    func testTwoStartsMakeOnePass() async {
        let runner = PassRunner()
        let gate = Gate()
        let first = runner.start(waitingBody(gate))
        let second = runner.start(waitingBody(gate))
        XCTAssertTrue(first.isNew)
        XCTAssertFalse(second.isNew)
        await eventually { await gate.started == 1 }
        await gate.release()
        await runner.join()
        let started = await gate.started
        XCTAssertEqual(started, 1)
    }

    func testJoinWaitsForThePass() async {
        let runner = PassRunner()
        let gate = Gate()
        runner.start(waitingBody(gate))
        let joined = Task { await runner.join() }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(runner.isRunning)
        await gate.release()
        await joined.value
        XCTAssertFalse(runner.isRunning)
    }

    func testJoinWithNoPassReturnsAtOnce() async {
        await PassRunner().join()
    }

    func testCancellingJoinDoesNotStopThePass() async {
        let runner = PassRunner()
        let gate = Gate()
        runner.start(onEnd: { await gate.noteEnd(cancelled: $0) }, waitingBody(gate))
        let joined = Task { await runner.join() }
        joined.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(runner.isRunning)
        await gate.release()
        await joined.value
        await runner.join()
        let cancelled = await gate.cancelled
        XCTAssertEqual(cancelled, 0)
    }

    func testCancellingARunCallerCancelsThePass() async {
        let runner = PassRunner()
        let sawCancel = Gate()
        let caller = Task {
            await runner.run(onEnd: { await sawCancel.noteEnd(cancelled: $0) }) {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        await eventually { runner.isRunning }
        caller.cancel()
        await caller.value
        XCTAssertFalse(runner.isRunning)
        let cancelled = await sawCancel.cancelled
        XCTAssertEqual(cancelled, 1)
    }

    func testCancellingAJoinedRunCallerCancelsThePass() async {
        let runner = PassRunner()
        let gate = Gate()
        runner.start(onEnd: { await gate.noteEnd(cancelled: $0) }) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let joiner = Task { await runner.run { XCTFail("A second pass was started") } }
        try? await Task.sleep(for: .milliseconds(50))
        joiner.cancel()
        await joiner.value
        XCTAssertFalse(runner.isRunning)
        let cancelled = await gate.cancelled
        XCTAssertEqual(cancelled, 1)
    }

    func testAStartAfterThePassEndsMakesANewOne() async {
        let runner = PassRunner()
        let gate = Gate()
        await gate.release()
        let first = runner.start(waitingBody(gate))
        await first.task.value
        let second = runner.start(waitingBody(gate))
        XCTAssertTrue(second.isNew)
        await second.task.value
        let started = await gate.started
        XCTAssertEqual(started, 2)
    }

    func testOnEndRunsOnEveryExit() async {
        let runner = PassRunner()
        let gate = Gate()
        // Finishing normally.
        await runner.run(onEnd: { await gate.noteEnd(cancelled: $0) }) {}
        // Cancelled.
        let caller = Task {
            await runner.run(onEnd: { await gate.noteEnd(cancelled: $0) }) {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            }
        }
        await eventually { runner.isRunning }
        caller.cancel()
        await caller.value
        // Returning early, as a pass does when something isn't set up.
        await runner.run(onEnd: { await gate.noteEnd(cancelled: $0) }) { return }
        let ended = await gate.ended
        let cancelled = await gate.cancelled
        XCTAssertEqual(ended, 3)
        XCTAssertEqual(cancelled, 1)
    }

    func testASecondRunWhileOneIsGoingJoinsIt() async {
        let runner = PassRunner()
        let gate = Gate()
        let first = Task { await runner.run(waitingBody(gate)) }
        await eventually { runner.isRunning }
        let second = Task { await runner.run(waitingBody(gate)) }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.release()
        await first.value
        await second.value
        let started = await gate.started
        XCTAssertEqual(started, 1)
    }

    func testCancelAndWaitReturnsOnceThePassHasEnded() async {
        let runner = PassRunner()
        let gate = Gate()
        runner.start(onEnd: { await gate.noteEnd(cancelled: $0) }) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let wasRunning = await runner.cancelAndWait()
        XCTAssertTrue(wasRunning)
        let ended = await gate.ended
        XCTAssertEqual(ended, 1)
        let again = await runner.cancelAndWait()
        XCTAssertFalse(again)
    }

    func testANewPassCannotStartWhileOnEndIsRunning() async {
        let runner = PassRunner()
        let gate = Gate()
        let task = runner.start(onEnd: { _ in await gate.pass() }) {}.task
        await eventually { await gate.started == 1 }
        XCTAssertFalse(runner.start({}).isNew)
        await gate.release()
        await task.value
        XCTAssertTrue(runner.start({}).isNew)
    }

    // MARK: - A run of several parts, as BackupRun keeps them

    /// A run's own runner, with one runner per part inside it, the way the coordinator uses them.
    private final class Run: @unchecked Sendable {
        let whole = PassRunner()
        let parts = [PassRunner(), PassRunner()]
        let gate = Gate()

        func start() -> (task: Task<Void, Never>, isNew: Bool) {
            whole.start {
                async let first: Void = self.parts[0].run { await self.gate.hold() }
                async let second: Void = self.parts[1].run { await self.gate.hold() }
                _ = await (first, second)
            }
        }
    }

    func testARunStartedWhileOneIsGoingJoinsIt() async {
        let run = Run()
        XCTAssertTrue(run.start().isNew)
        XCTAssertFalse(run.start().isNew)
        await eventually { await run.gate.started == 2 }
        await run.gate.release()
        await run.whole.join()
        let started = await run.gate.started
        XCTAssertEqual(started, 2)
    }

    func testPausingOnePartLeavesTheOtherRunning() async {
        let run = Run()
        run.start()
        await eventually { await run.gate.started == 2 }
        run.parts[0].cancel()
        await eventually { !run.parts[0].isRunning }
        XCTAssertTrue(run.parts[1].isRunning)
        XCTAssertTrue(run.whole.isRunning)
        await run.gate.release()
        await run.whole.join()
    }

    func testCancellingTheRunCancelsEveryPart() async {
        let run = Run()
        run.start()
        await eventually { await run.gate.started == 2 }
        await run.whole.cancelAndWait()
        XCTAssertFalse(run.parts[0].isRunning)
        XCTAssertFalse(run.parts[1].isRunning)
    }

    /// As a continued task does: attached while a run is going, it ends when the run's last part does,
    /// and attached once the run has ended, it ends at once.
    func testATaskAttachedToARunningRunEndsWithIt() async {
        let run = Run()
        run.start()
        await eventually { await run.gate.started == 2 }
        let attached = Task { await run.whole.join() }
        run.parts[0].cancel()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(run.whole.isRunning)
        await run.gate.release()
        await attached.value
        XCTAssertFalse(run.whole.isRunning)
        await run.whole.join()
    }

    // MARK: - PartBarrier

    func testAQuickPartWaitsForTheOthersToPrepare() async {
        let barrier = PartBarrier<String>()
        barrier.expect(["bucket", "drive"])
        let quick = Task { await barrier.ready("bucket") }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(quick.isCancelled)
        let order = Gate()
        let waiting = Task {
            await quick.value
            await order.noteEnd(cancelled: false)
        }
        try? await Task.sleep(for: .milliseconds(50))
        var ended = await order.ended
        XCTAssertEqual(ended, 0)
        await barrier.ready("drive")
        await waiting.value
        ended = await order.ended
        XCTAssertEqual(ended, 1)
    }

    func testAPartThatEndsReleasesTheOthers() async {
        let barrier = PartBarrier<String>()
        barrier.expect(["bucket", "drive"])
        let waiting = Task { await barrier.ready("bucket") }
        try? await Task.sleep(for: .milliseconds(20))
        barrier.ended("drive")
        await waiting.value
    }

    func testAPausedPartStopsWaiting() async {
        let barrier = PartBarrier<String>()
        barrier.expect(["bucket", "drive"])
        let waiting = Task { await barrier.ready("bucket") }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await waiting.value
    }

    func testAPartJoiningLaterDoesntWait() async {
        let barrier = PartBarrier<String>()
        barrier.expect(["bucket"])
        await barrier.ready("bucket")
        barrier.expect(["drive"])
        await barrier.ready("drive")
    }

    // MARK: - OnceEach

    func testAJobIsDoneOncePerRun() async throws {
        let once = OnceEach<String>()
        let gate = Gate()
        let first = Task { try await once.run("bucket") { await gate.pass() } }
        await eventually { await gate.started == 1 }
        let second = Task { try await once.run("bucket") { await gate.pass() } }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.release()
        try await first.value
        try await second.value
        try await once.run("bucket") { XCTFail("Done again") }
        let started = await gate.started
        XCTAssertEqual(started, 1)
        XCTAssertTrue(once.isDone("bucket"))
    }

    func testAFailedJobIsTriedAgainByTheNextCaller() async throws {
        let once = OnceEach<String>()
        do {
            try await once.run("drive") { throw CancellationError() }
            XCTFail("Didn't throw")
        } catch {}
        XCTAssertFalse(once.isDone("drive"))
        var ran = false
        try await once.run("drive") { ran = true }
        XCTAssertTrue(ran)
    }

    func testAWaiterTakesOverWhenTheJobsCallerIsCancelled() async throws {
        let once = OnceEach<String>()
        let owner = Task {
            try await once.run("drive") {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                throw CancellationError()
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let ran = Gate()
        let waiter = Task { try await once.run("drive") { await ran.noteEnd(cancelled: false) } }
        try? await Task.sleep(for: .milliseconds(20))
        owner.cancel()
        try await waiter.value
        let ended = await ran.ended
        XCTAssertEqual(ended, 1)
    }

    // MARK: - KeyedLock

    func testTheSamePhotoIsntWorkedOnTwiceAtOnce() async {
        let lock = KeyedLock()
        let gate = Gate()
        let first = Task { await lock.withLock("a") { await gate.pass() } }
        await eventually { await gate.started == 1 }
        let second = Task { await lock.withLock("a") { await gate.pass() } }
        let other = Task { await lock.withLock("b") { await gate.noteEnd(cancelled: false) } }
        await other.value
        try? await Task.sleep(for: .milliseconds(50))
        var started = await gate.started
        XCTAssertEqual(started, 1)
        await gate.release()
        await first.value
        await second.value
        started = await gate.started
        XCTAssertEqual(started, 2)
    }
}
