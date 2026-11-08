import Foundation
import S3Kit
import SyncKit
import UIKit

/// The one way anything starts backing up or syncing. A run does, in order:
/// 1. the library snapshot;
/// 2. staging for the bucket and copying to the drive side by side, each first preparing the
///    listings it needs (once per run) and waiting for the other to have prepared too;
/// 3. the sync.
///
/// `RunPlan` decides which parts a run does. One run goes at a time: starting while one is going
/// adds to it what the user asked for. Pausing a row stops just that part.
final class BackupRun: @unchecked Sendable {
    typealias Part = RunPlan.Part

    static let shared = BackupRun()

    private let lock = NSLock()
    private var current: Run?
    /// When the last run started and finished, for `RunPlan`'s throttle.
    private var lastRun: ClosedRange<Date>?
    private var lastSituation: Situation?

    // MARK: - Entry points

    /// Starts a run, or adds to the one going. Synchronous, so a continued task requested straight
    /// after finds the run it's for.
    static func start(_ trigger: RunPlan.Trigger, because reason: String) {
        shared.start(trigger, reason: reason)
    }

    /// A tap on a row's button: that part, then the sync, carrying on in the background under a
    /// continued task.
    @MainActor static func tap(_ part: Part) {
        start(.user([part]), because: "tap on \(part.rawValue)")
        ContinuedRunTask.requestIfNeeded()
    }

    /// The drive appearing while the app is open counts as the user's doing.
    @MainActor static func drivePlugged() {
        start(.user([.drive]), because: "drive plugged in")
        ContinuedRunTask.requestIfNeeded()
    }

    /// The app becoming active with the drive attached counts as plugging it in, when there are
    /// photos to copy: the opening run gets a continued task, or keeps the one it has. Called
    /// straight after the opening run starts, from the activation itself.
    @MainActor static func opened() {
        let setup = Situation.now().setup
        // Nothing is asked of the drive, or the store, unless a drive is set up and switched on.
        guard setup.drive, setup.driveAutoBackup, DriveDestination.isConnected, let driveID = DriveDestination.id else { return }
        // The library hasn't been listed yet, so go by counts: what's in it, less the low-res copies
        // left out of the backup, less what the drive has. Photos edited since are missed.
        let store = BackupStore.shared
        let inLibrary = PhotoLibrary.isAuthorized ? PhotoLibrary.fetchAllAssets().count : 0
        let imported = store.importedAssetIDs().count
        let onDrive = store.completedDriveAssets(driveID: driveID).count
        let uncopied = inLibrary - imported - onDrive
        Log.run.info("Opened with the drive attached: about \(max(uncopied, 0)) to copy (\(inLibrary) in the library, \(imported) imported, \(onDrive) on the drive)")
        guard RunPlan.requestsTaskWhenOpened(setup: setup, driveReachable: true, uncopied: uncopied)
        else { return Log.run.info("Opened with the drive attached and nothing to copy: no continued task") }
        start(.user([.drive]), because: "app opened with the drive attached")
        ContinuedRunTask.requestIfNeeded()
    }

    /// Pauses one row's part of the run. The rest carries on.
    static func pause(_ part: Part) {
        Log.run.info("Pausing \(part.rawValue, privacy: .public)")
        switch part {
        case .bucket: BackupEngine.stop()
        case .drive: DriveBackupEngine.stop()
        case .sync: LibrarySyncEngine.stop()
        }
    }

    /// Stops the whole run, as when iOS ends the time it gave. Its rows say "Stopped".
    static func stopAll(because reason: String) {
        guard let run = shared.lock.withLock({ shared.current }) else { return }
        Log.run.info("Stopping the run: \(reason, privacy: .public)")
        run.stop()
    }

    /// Starts a run (or joins the one going) and waits for it to end.
    func run(_ trigger: RunPlan.Trigger, because reason: String) async {
        start(trigger, reason: reason)
        await join()
    }

    /// Waits for the run going, if there is one.
    func join() async {
        let main = lock.withLock { current?.main }
        await main?.value
    }

    /// What a part that was stopped says: "Stopped" when the whole run was, "Paused" for a row.
    static var pausedPhase: String {
        shared.lock.withLock { shared.current?.isStopped == true } ? "Stopped" : "Paused"
    }

    /// For the sync preview, which lists outside a run: decided as for a run starting now.
    static func preparation() -> RunPreparation {
        shared.lock.withLock {
            let situation = Situation.now()
            return RunPreparation(lastRun: shared.lastRun, started: Date(),
                                  bucketChanged: shared.lastSituation.map { $0.bucket != situation.bucket } ?? false,
                                  driveChanged: shared.lastSituation.map { $0.drive != situation.drive } ?? false)
        }
    }

    // MARK: - The run

    private func start(_ trigger: RunPlan.Trigger, reason: String) {
        // Before the phone's first unlock, say, in the background. The next run catches up.
        guard BackupStore.open() != nil else {
            return Log.run.error("No run for \(reason, privacy: .public): the backup database can't be opened")
        }
        let now = Date()
        let situation = Situation.now()
        lock.withLock {
            if let current {
                let added = current.add(RunPlan.joining(trigger, setup: situation.setup))
                Log.run.info("Run going: \(reason, privacy: .public) joins it\(added.isEmpty ? "" : ", adding \(Self.names(added))", privacy: .public)")
                ContinuedRunTask.partsAdded(current.plannedParts)
                return
            }
            let changed = lastSituation.map { $0 != situation } ?? false
            guard let parts = RunPlan.parts(for: trigger, setup: situation.setup, lastRunEnded: lastRun?.upperBound,
                                            setupChanged: changed, now: now)
            else {
                Log.run.info("No run for \(reason, privacy: .public): the last ended less than \(Int(RunPlan.throttle)) s ago")
                return
            }
            let preparation = RunPreparation(lastRun: lastRun, started: now,
                                             bucketChanged: lastSituation.map { $0.bucket != situation.bucket } ?? false,
                                             driveChanged: lastSituation.map { $0.drive != situation.drive } ?? false)
            let run = Run(reason: reason, parts: parts, setup: situation.setup, started: now, preparation: preparation)
            current = run
            lastSituation = situation
            run.main = Task.detached(priority: .utility) { await self.perform(run) }
        }
    }

    private func perform(_ run: Run) async {
        Log.run.info("Run started (\(run.reason, privacy: .public)): \(Self.names(run.plannedParts), privacy: .public)")
        ContinuedRunTask.runStarted(parts: run.plannedParts)
        let backgroundTime = await BackgroundTime.begin()

        await step("library snapshot") { _ = await LibrarySnapshot.current() }

        let working = run.beginWorking()
        if !working.isEmpty {
            await step("backing up (\(Self.names(working)))") { await run.waitForParts() }
        }
        if !Task.isCancelled && run.beginSyncing() {
            await step("sync") { await run.waitForParts() }
        }
        // Parts asked for while the run was ending.
        repeat {
            await run.waitForParts()
        } while !endIfIdle(run)

        Log.run.info("Run ended after \(Date().timeIntervalSince(run.started), format: .fixed(precision: 1)) s\(run.isStopped ? ", stopped" : "", privacy: .public)")
        ContinuedRunTask.runEnded()
        await backgroundTime?.end()
    }

    private func endIfIdle(_ run: Run) -> Bool {
        lock.withLock {
            guard run.end() else { return false }
            current = nil
            lastRun = run.started...Date()
            return true
        }
    }

    private func step(_ name: String, _ body: () async -> Void) async {
        Log.run.info("Step started: \(name, privacy: .public)")
        await body()
        Log.run.info("Step ended: \(name, privacy: .public)\(Task.isCancelled ? ", stopped" : "", privacy: .public)")
    }

    fileprivate static func names(_ parts: Set<Part>) -> String {
        Part.allCases.filter(parts.contains).map(\.rawValue).joined(separator: ", ")
    }

    /// What's set up, and where to: a change to any of it since the last run lifts the throttle.
    private struct Situation: Equatable {
        let setup: RunPlan.Setup
        let bucket: String?
        let drive: String?

        static func now() -> Situation {
            let settings = SettingsStore.snapshot()
            let client = settings.flatMap { try? S3Client(config: $0.s3) }
            let bucket = settings.flatMap { settings in client.map { StorageInventory.identity(client: $0, prefix: settings.prefix) } }
            let setup = RunPlan.Setup(bucket: bucket != nil, autoBackup: settings?.autoBackup ?? false,
                                      drive: DriveDestination.id != nil, driveAutoBackup: SettingsStore.driveAutoBackup,
                                      sync: SettingsStore.syncEnabled)
            return Situation(setup: setup, bucket: bucket, drive: DriveDestination.id)
        }
    }
}

/// For a run started in the foreground: a little time to reach a safe stopping point if the app is
/// left. Runs the app starts on its own never get a continued task, so when this time runs out the
/// run stops, unless a tap has given it one since.
@MainActor
private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    static func begin() -> BackgroundTime? {
        guard UIApplication.shared.applicationState != .background else { return nil }
        let time = BackgroundTime()
        time.identifier = UIApplication.shared.beginBackgroundTask(withName: "Backup run") {
            if !ContinuedRunTask.isAttached {
                BackupRun.stopAll(because: "the app's time in the background ran out")
            }
            time.end()
        }
        return time.identifier == .invalid ? nil : time
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// One run in progress: what it's doing, and what its parts share.
final class Run: @unchecked Sendable {
    typealias Part = RunPlan.Part

    private enum Stage { case starting, working, syncing, ended }

    let reason: String
    let setup: RunPlan.Setup
    let started: Date
    let preparation: RunPreparation
    /// Staging and copying start their work together, once both have prepared.
    let barrier = PartBarrier<Part>()
    /// Staging and copying never work on the same photo's paths at once.
    let photoLock = KeyedLock()
    fileprivate var main: Task<Void, Never>?

    private let lock = NSLock()
    private var parts: Set<Part>
    private var stage = Stage.starting
    private var tasks: [Part: Task<Void, Never>] = [:]
    private var stopped = false

    fileprivate init(reason: String, parts: Set<Part>, setup: RunPlan.Setup, started: Date, preparation: RunPreparation) {
        self.reason = reason
        self.parts = parts
        self.setup = setup
        self.started = started
        self.preparation = preparation
    }

    /// What the run does, including parts added since it started.
    var plannedParts: Set<Part> {
        lock.withLock { parts }
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    /// Returns the parts that weren't already going.
    fileprivate func add(_ asked: Set<Part>) -> Set<Part> {
        lock.withLock {
            guard !stopped else { return [] }
            let added = asked.filter { tasks[$0] == nil }
            for part in added {
                parts.insert(part)
                switch (stage, part) {
                case (.starting, _), (.working, .sync), (.ended, _):
                    // Started when the run gets to it.
                    break
                case (.working, _), (.syncing, _):
                    Log.run.info("Part added to the run: \(part.rawValue, privacy: .public)")
                    if part != .sync { barrier.expect([part]) }
                    spawn(part)
                }
            }
            return added
        }
    }

    /// Starts staging and copying. Returns which.
    fileprivate func beginWorking() -> Set<Part> {
        lock.withLock {
            stage = .working
            guard !stopped else { return [] }
            let working = parts.subtracting([.sync])
            barrier.expect(working)
            working.forEach(spawn)
            return working
        }
    }

    /// Starts the sync, if the run does one. Returns whether it did.
    fileprivate func beginSyncing() -> Bool {
        lock.withLock {
            stage = .syncing
            guard !stopped, parts.contains(.sync), tasks[.sync] == nil else { return false }
            spawn(.sync)
            return true
        }
    }

    /// Waits until no part is going.
    fileprivate func waitForParts() async {
        while let task = lock.withLock({ tasks.values.first }) {
            await task.value
        }
    }

    /// Whether it has ended, which it does once no part is going.
    fileprivate func end() -> Bool {
        lock.withLock {
            guard tasks.isEmpty else { return false }
            stage = .ended
            return true
        }
    }

    fileprivate func stop() {
        let running: [Task<Void, Never>] = lock.withLock {
            stopped = true
            return Array(tasks.values) + [main].compactMap { $0 }
        }
        running.forEach { $0.cancel() }
    }

    /// With the lock held.
    private func spawn(_ part: Part) {
        tasks[part] = Task.detached(priority: .utility) {
            switch part {
            case .bucket: await BackupEngine.shared.run(in: self)
            case .drive: await DriveBackupEngine.shared.run(in: self)
            case .sync: await LibrarySyncEngine.shared.run(in: self)
            }
            ContinuedRunTask.partEnded(part)
            self.lock.withLock { self.tasks[part] = nil }
            self.barrier.ended(part)
        }
    }
}

/// Preparing storage, once per run: each place's handled paths merged and its listing made, or
/// the last run's used where `RunPlan` allows it.
final class RunPreparation: Sendable {
    private enum Place: Hashable, Sendable { case drive, bucket }

    private let lastRun: ClosedRange<Date>?
    private let started: Date
    private let bucketChanged: Bool
    private let driveChanged: Bool
    private let once = OnceEach<Place>()

    fileprivate init(lastRun: ClosedRange<Date>?, started: Date, bucketChanged: Bool, driveChanged: Bool) {
        self.lastRun = lastRun
        self.started = started
        self.bucketChanged = bucketChanged
        self.driveChanged = driveChanged
    }

    var isBucketPrepared: Bool { once.isDone(.bucket) }

    func prepareDrive(root: URL, driveID: String, progress: ((Int) async -> Void)? = nil) async throws {
        try await once.run(.drive) {
            let listing = RunPlan.listing(listedAt: StorageInventory.driveListedAt(driveID: driveID), lastRun: lastRun,
                                          now: started, changed: driveChanged)
            Log.run.info("Step started: preparing the drive (\(listing == .list ? "listing it" : "using the last run's listing", privacy: .public))")
            do {
                try await StorageInventory.prepareDrive(root: root, driveID: driveID, list: listing == .list, progress: progress)
            } catch {
                Log.run.info("Step ended: preparing the drive, \(Task.isCancelled ? "paused" : "failed", privacy: .public)")
                throw error
            }
            Log.run.info("Step ended: preparing the drive")
        }
    }

    func prepareBucket(client: S3Client, prefix: String, session: URLSession, progress: ((Int) async -> Void)? = nil) async throws {
        try await once.run(.bucket) {
            let listing = RunPlan.listing(listedAt: StorageInventory.bucketListedAt(client: client, prefix: prefix), lastRun: lastRun,
                                          now: started, changed: bucketChanged,
                                          refusesTakenNames: !StorageInventory.lacksConditionalWrites(client: client, prefix: prefix))
            Log.run.info("Step started: preparing the bucket (\(listing == .list ? "listing it" : "using the last run's listing", privacy: .public))")
            do {
                try await StorageInventory.prepareS3(client: client, prefix: prefix, session: session, list: listing == .list, progress: progress)
            } catch {
                Log.run.info("Step ended: preparing the bucket, \(Task.isCancelled ? "paused" : "failed", privacy: .public)")
                throw error
            }
            Log.run.info("Step ended: preparing the bucket")
        }
    }
}
