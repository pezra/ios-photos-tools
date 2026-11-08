import Testing
@testable import SyncKit

@Suite struct RunProgressTests {
    typealias Step = RunProgress.Step

    @Test func sharesFixedPerPart() {
        let progress = RunProgress(parts: [.drive, .bucket])
        #expect(progress.shares.map(\.share).reduce(0, +) == 200)
        #expect(progress.shares.count == 4)
    }

    @Test func stepsFillTheirShare() {
        var progress = RunProgress(parts: [.drive])
        progress.update(Step(.drive, .listing), completed: 50, of: 100)
        #expect(abs(progress.fraction - 0.1) < 1e-9)
        progress.finish(Step(.drive, .listing))
        #expect(abs(progress.fraction - 0.2) < 1e-9)
        progress.update(Step(.drive, .work), completed: 1, of: 4)
        #expect(abs(progress.fraction - 0.4) < 1e-9)
        progress.finish(.drive)
        #expect(progress.fraction == 1)
    }

    @Test func learningTheSizeDoesNotGoBackwards() {
        var progress = RunProgress(parts: [.sync])
        let step = Step(.sync, .listing)
        var last = 0.0
        // First an unknown total, then a smaller known one, then a bigger one.
        for (done, total) in [(10.0, nil), (500, nil), (600, 10_000.0), (700, 700.0), (700, 5_000.0)] as [(Double, Double?)] {
            progress.update(step, completed: done, of: total)
            #expect(progress.fraction >= last)
            last = progress.fraction
        }
    }

    @Test func unknownTotalNeverReachesTheEnd() {
        var progress = RunProgress(parts: [.bucket])
        progress.update(Step(.bucket, .listing), completed: 10_000_000, of: nil)
        #expect(progress.fraction(of: Step(.bucket, .listing)) < 0.9)
    }

    @Test func stepFractionNeverGoesDown() {
        var progress = RunProgress(parts: [.drive])
        let step = Step(.drive, .work)
        progress.update(step, completed: 8, of: 10)
        progress.update(step, completed: 2, of: 10)
        #expect(progress.fraction(of: step) == 0.8)
    }

    @Test func nothingHappensToStepsNotStarted() {
        var progress = RunProgress(parts: [.drive])
        progress.nudge()
        #expect(progress.fraction == 0)
    }

    @Test func nudgesStopAtTheCap() {
        var progress = RunProgress(parts: [.drive])
        let step = Step(.drive, .work)
        progress.update(step, completed: 1, of: 10)
        for _ in 0..<1000 { progress.nudge() }
        #expect(abs(progress.fraction(of: step) - (0.1 + RunProgress.nudgeCap)) < 1e-9)
        // Real progress carries on from there, and never below.
        progress.update(step, completed: 1.2, of: 10)
        #expect(progress.fraction(of: step) >= 0.13)
        progress.update(step, completed: 5, of: 10)
        #expect(progress.fraction(of: step) == 0.5)
    }

    @Test func nudgesNeverFinishAStep() {
        var progress = RunProgress(parts: [.drive])
        let step = Step(.drive, .work)
        progress.update(step, completed: 99, of: 100)
        for _ in 0..<1000 { progress.nudge() }
        #expect(progress.fraction(of: step) < 1)
    }

    @Test func nudgesLeaveFinishedStepsAlone() {
        var progress = RunProgress(parts: [.drive])
        progress.finish(.drive)
        progress.nudge()
        #expect(progress.fraction == 1)
    }

    @Test func addingAPartDoesNotMoveTheTotalBack() {
        var progress = RunProgress(parts: [.drive])
        progress.finish(.drive)
        #expect(progress.fraction == 1)
        progress.add(.sync)
        #expect(progress.fraction == 1)
        progress.update(Step(.sync, .work), completed: 1, of: 2)
        #expect(progress.fraction == 1)
        progress.add(.sync)
        #expect(progress.parts == [.drive, .sync])
    }

    @Test func updatesToAPartNotInTheRunAreIgnored() {
        var progress = RunProgress(parts: [.drive])
        progress.update(Step(.bucket, .work), completed: 5, of: 5)
        #expect(progress.fraction == 0)
    }

    @Test func emptyTotalCountsAsDone() {
        var progress = RunProgress(parts: [.drive])
        progress.update(Step(.drive, .work), completed: 0, of: 0)
        #expect(progress.fraction(of: Step(.drive, .work)) == 1)
    }

    @Test func downloadThenWrite() {
        var transfer = TransferProgress(size: 100)
        transfer.download(0.5)
        #expect(transfer.fraction() == 0.25)
        transfer.download(1)
        transfer.wrote(50)
        #expect(transfer.fraction() == 0.75)
        transfer.wrote(100)
        #expect(transfer.fraction() == 1)
    }

    @Test func writeOnly() {
        var transfer = TransferProgress(size: 200)
        transfer.wrote(50)
        #expect(transfer.fraction() == 0.25)
    }

    @Test func unknownSizeShowsNothingUntilDone() {
        var transfer = TransferProgress(size: nil)
        transfer.wrote(1_000)
        #expect(transfer.fraction() == 0)
        transfer.download(0.4)
        #expect(abs(transfer.fraction() - 0.2) < 1e-9)
    }

    @Test func transferNeverGoesBack() {
        var transfer = TransferProgress(size: 100)
        transfer.wrote(60)
        #expect(transfer.fraction() == 0.6)
        transfer.download(0.1)
        // 0.05 + 0.3 is less than 0.6.
        #expect(transfer.fraction() == 0.6)
    }
}
