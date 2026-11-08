import Foundation
import Testing
@testable import SyncKit

@Suite struct RunPlanTests {
    private let everything = RunPlan.Setup(bucket: true, autoBackup: true, drive: true, driveAutoBackup: true, sync: true)
    private let now = Date(timeIntervalSince1970: 100_000)

    private func parts(_ trigger: RunPlan.Trigger, _ setup: RunPlan.Setup? = nil, lastEnded: TimeInterval? = nil,
                       changed: Bool = false) -> Set<RunPlan.Part>? {
        RunPlan.parts(for: trigger, setup: setup ?? everything, lastRunEnded: lastEnded.map { now.addingTimeInterval(-$0) },
                      setupChanged: changed, now: now)
    }

    // MARK: - Parts

    @Test func openingRunsWhatsSwitchedOn() {
        #expect(parts(.opened) == [.bucket, .drive, .sync])
        var setup = everything
        setup.autoBackup = false
        setup.driveAutoBackup = false
        #expect(parts(.opened, setup) == [.sync])
    }

    @Test func noDriveLeavesTheDriveOut() {
        var setup = everything
        setup.drive = false
        #expect(parts(.opened, setup) == [.bucket, .sync])
        #expect(parts(.user([.drive]), setup) == [.sync])
        #expect(RunPlan.needs(.sync, pending: 0, parts: [.bucket, .sync], setup: setup) == (false, true))
    }

    @Test func noBucketLeavesTheBucketOut() {
        var setup = everything
        setup.bucket = false
        #expect(parts(.opened, setup) == [.drive, .sync])
        #expect(parts(.uploadsSettled, setup) == [])
        #expect(RunPlan.needs(.drive, pending: 5, parts: [.drive, .sync], setup: setup) == (true, false))
    }

    @Test func syncOffLeavesTheSyncOut() {
        var setup = everything
        setup.sync = false
        #expect(parts(.opened, setup) == [.bucket, .drive])
        #expect(parts(.user([.bucket]), setup) == [.bucket])
        #expect(parts(.user([.sync]), setup) == [])
        // The drive is only listed for copying, and for the sync.
        #expect(RunPlan.needs(.drive, pending: 0, parts: [.drive], setup: setup) == (false, false))
        #expect(RunPlan.needs(.drive, pending: 0, parts: [.drive, .sync], setup: everything) == (true, false))
    }

    @Test func aTapRunsItsPartThenTheSync() {
        #expect(parts(.user([.bucket])) == [.bucket, .sync])
        #expect(parts(.user([.drive])) == [.drive, .sync])
        #expect(parts(.user([.sync])) == [.sync])
        #expect(parts(.uploadsSettled) == [.bucket])
    }

    @Test func joiningOnlyAddsWhatWasAskedFor() {
        #expect(RunPlan.joining(.opened, setup: everything) == [])
        #expect(RunPlan.joining(.automatic, setup: everything) == [])
        #expect(RunPlan.joining(.user([.drive]), setup: everything) == [.drive])
        #expect(RunPlan.joining(.uploadsSettled, setup: everything) == [.bucket])
    }

    @Test func copyingNeedsBothListingsAndStagingTheBucketsAlone() {
        #expect(RunPlan.needs(.drive, pending: 3, parts: [.drive], setup: everything) == (true, true))
        #expect(RunPlan.needs(.drive, pending: 3, parts: [.bucket, .drive], setup: everything) == (true, true))
        #expect(RunPlan.needs(.bucket, pending: 3, parts: [.bucket, .drive], setup: everything) == (false, true))
        #expect(RunPlan.needs(.bucket, pending: 0, parts: [.bucket], setup: everything) == (false, false))
    }

    // MARK: - Throttle

    @Test func openingWithinTheThrottleStartsNoRun() {
        #expect(parts(.opened, lastEnded: 60) == nil)
        #expect(parts(.opened, lastEnded: RunPlan.throttle - 1) == nil)
        #expect(parts(.opened, lastEnded: RunPlan.throttle) == [.bucket, .drive, .sync])
        #expect(parts(.opened, lastEnded: nil) == [.bucket, .drive, .sync])
    }

    @Test func tapsAndTheBackgroundTaskArentThrottled() {
        #expect(parts(.user([.bucket]), lastEnded: 10) == [.bucket, .sync])
        #expect(parts(.automatic, lastEnded: 10) == [.bucket, .drive, .sync])
        #expect(parts(.uploadsSettled, lastEnded: 10) == [.bucket])
    }

    @Test func aChangedSetupIsntThrottled() {
        #expect(parts(.opened, lastEnded: 10, changed: true) == [.bucket, .drive, .sync])
    }

    // MARK: - Listings

    private func listing(listedAt: TimeInterval?, lastRun: (started: TimeInterval, ended: TimeInterval)?,
                         changed: Bool = false, refuses: Bool = true) -> RunPlan.Listing {
        RunPlan.listing(listedAt: listedAt.map { now.addingTimeInterval(-$0) },
                        lastRun: lastRun.map { now.addingTimeInterval(-$0.started)...now.addingTimeInterval(-$0.ended) },
                        now: now, changed: changed, refusesTakenNames: refuses)
    }

    @Test func theLastRunsListingIsUsedWithinTheThrottle() {
        #expect(listing(listedAt: 200, lastRun: (300, 60)) == .reuse)
    }

    @Test func aListingIsMadeAgainOutsideTheThrottle() {
        #expect(listing(listedAt: 400, lastRun: (500, RunPlan.throttle)) == .list)
        #expect(listing(listedAt: 200, lastRun: nil) == .list)
    }

    @Test func aListingFromBeforeTheLastRunIsMadeAgain() {
        #expect(listing(listedAt: 400, lastRun: (300, 60)) == .list)
        #expect(listing(listedAt: nil, lastRun: (300, 60)) == .list)
    }

    @Test func aBucketWithoutConditionalWritesIsAlwaysListed() {
        #expect(listing(listedAt: 200, lastRun: (300, 60), refuses: false) == .list)
    }

    @Test func aChangedDestinationIsListed() {
        #expect(listing(listedAt: 200, lastRun: (300, 60), changed: true) == .list)
    }
}
