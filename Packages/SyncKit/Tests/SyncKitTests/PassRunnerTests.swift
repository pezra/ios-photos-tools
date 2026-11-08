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
}
