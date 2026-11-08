import BackgroundTasks
import Foundation
import Photos
import SyncKit

/// Lets a run the user started keep going after the app is closed, with its progress shown by the
/// system. Requested only in direct response to a tap (or the drive being plugged in), never for a
/// run the app started on its own. One task per run: a tap during a run that has one joins it.
final class ContinuedRunTask: @unchecked Sendable {
    static let backupTitle = "Backing up photos"
    static let syncTitle = "Syncing pictures to this phone"
    /// `org.barelyenough.ios-photos-tools.run.*` is permitted in Info.plist.
    private static let identifierPrefix = "org.barelyenough.ios-photos-tools.run."

    private static let shared = ContinuedRunTask()

    private enum State {
        case none
        case requested
        case attached(BGContinuedProcessingTask)
    }

    private let lock = NSLock()
    private var state = State.none
    /// The run's progress, summed over its steps. Built for every run, whether or not it has a
    /// task, so the values can be followed in the log where no task can be had.
    private var aggregate = RunProgress()
    private var tree: Progress?
    private var children: [RunProgress.Step: Progress] = [:]
    private var lastLogged: (fraction: Double, at: Date)?
    /// iOS ends a continued task whose progress hasn't moved for a while (about 30 seconds, going
    /// by other developers' reports). Copying a big video, or downloading it from iCloud first, can
    /// take longer than that, so while there's a task its progress is nudged along, a little and
    /// never far past what has really been done. Work that gives a signal doesn't need it.
    private var heartbeat: Task<Void, Never>?
    private static let nudgeInterval: Duration = .seconds(5)
    /// The task's progress is this many units, since iOS may only advance whole ones.
    private static let taskUnits: Int64 = 1000
    private static let childUnits: Int64 = 1000

    private var task: BGContinuedProcessingTask? {
        if case .attached(let task) = state { return task }
        return nil
    }

    // MARK: - Requesting

    /// Must be called while the app is in the foreground, from the tap itself.
    @MainActor static func requestIfNeeded() {
        let skip: Bool = shared.lock.withLock {
            if case .none = shared.state {
                shared.state = .requested
                return false
            }
            return true
        }
        guard !skip else {
            return Log.continuedTask.info("Continued task not requested: the run already has one")
        }
        // Continued-processing handlers can be registered after launch, but only once per
        // identifier, so each request gets its own.
        let identifier = identifierPrefix + UUID().uuidString
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            shared.attach(task)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: backupTitle, subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.continuedTask.info("Continued task requested")
        } catch {
            // The run goes ahead in the foreground regardless.
            shared.lock.withLock { shared.state = .none }
            Log.continuedTask.error("Couldn't continue the run in the background: \(error, privacy: .public)")
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        Log.continuedTask.info("Continued task attached")
        task.expirationHandler = {
            Log.continuedTask.info("Continued task expired or stopped")
            BackupRun.stopAll(because: "the continued task expired or was stopped")
        }
        lock.withLock {
            state = .attached(task)
            show()
            heartbeat = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.nudgeInterval)
                    self.nudge()
                }
            }
        }
        Task.detached {
            // Returns at once if the run has already ended, as when there was nothing to do.
            await BackupRun.shared.join()
            self.lock.withLock {
                self.heartbeat?.cancel()
                self.heartbeat = nil
                self.state = .none
            }
            // Even when it expired: the handler can't tell iOS cutting it short from the user
            // stopping it, and failure would show a "failed" notification for a stop they chose.
            // A run cut short carries on next time anyway.
            task.setTaskCompleted(success: true)
            Log.continuedTask.info("Continued task ended")
        }
    }

    /// Whether the run has a continued task now.
    static var isAttached: Bool {
        shared.lock.withLock { shared.task != nil }
    }

    // MARK: - The run's progress

    /// Builds the tree: a parent with a child per step, each with its fixed share.
    static func runStarted(parts: @autoclosure () -> Set<RunPlan.Part>) {
        shared.lock.withLock {
            shared.aggregate = RunProgress()
            shared.tree = Progress(totalUnitCount: 0)
            shared.children = [:]
            shared.lastLogged = nil
            shared.add(parts())
            Log.continuedTask.info("Progress started: \(shared.aggregate.shares.map { "\($0.step.part.rawValue) \($0.step.kind) \($0.share)" }.joined(separator: ", "), privacy: .public)")
            shared.show()
        }
    }

    /// Parts that joined the run after it started.
    static func partsAdded(_ parts: Set<RunPlan.Part>) {
        shared.lock.withLock {
            guard shared.tree != nil else { return }
            shared.add(parts)
        }
    }

    /// A task requested for a run that ended before iOS handed it over is completed when it arrives.
    /// Until then a tap may request another.
    static func runEnded() {
        shared.lock.withLock {
            if case .requested = shared.state { shared.state = .none }
            shared.log(force: true, note: "run ended")
            shared.tree = nil
            shared.children = [:]
        }
    }

    /// How far a step has got in its own units. A total that isn't known yet is nil.
    static func update(_ part: RunPlan.Part, _ kind: RunProgress.Kind, completed: Double, of total: Double?) {
        shared.lock.withLock {
            guard shared.tree != nil else { return }
            shared.aggregate.update(.init(part, kind), completed: completed, of: total)
            shared.show()
        }
    }

    static func update(_ part: RunPlan.Part, _ kind: RunProgress.Kind, completed: Int, of total: Int?) {
        update(part, kind, completed: Double(completed), of: total.map(Double.init))
    }

    static func finish(_ part: RunPlan.Part, _ kind: RunProgress.Kind) {
        shared.lock.withLock {
            guard shared.tree != nil else { return }
            shared.aggregate.finish(.init(part, kind))
            shared.show()
        }
    }

    /// A part that has ended, however it ended, has nothing more to do.
    static func partEnded(_ part: RunPlan.Part) {
        shared.lock.withLock {
            guard shared.tree != nil else { return }
            shared.aggregate.finish(part)
            shared.show()
        }
    }

    static func phase(_ part: RunPlan.Part, _ phase: String) {
        shared.lock.withLock { shared.show(part, phase: phase) }
    }

    private func nudge() {
        lock.withLock {
            guard tree != nil else { return }
            aggregate.nudge()
            show()
        }
    }

    /// With the lock held.
    private func add(_ parts: Set<RunPlan.Part>) {
        guard let tree else { return }
        for part in RunPlan.Part.allCases where parts.contains(part) && !aggregate.parts.contains(part) {
            aggregate.add(part)
            for (step, share) in aggregate.shares where step.part == part {
                let child = Progress(totalUnitCount: Self.childUnits)
                tree.totalUnitCount += share
                tree.addChild(child, withPendingUnitCount: share)
                children[step] = child
            }
        }
    }

    /// With the lock held. Passes the steps' fractions to their children, and the total to the task.
    private func show(_ part: RunPlan.Part? = nil, phase: String? = nil) {
        for (step, child) in children {
            let units = Int64(aggregate.fraction(of: step) * Double(Self.childUnits))
            if child.completedUnitCount != units { child.completedUnitCount = units }
        }
        log(force: false, note: nil)
        guard let task else { return }
        if let phase, let part {
            task.updateTitle(part == .sync ? Self.syncTitle : Self.backupTitle, subtitle: phase)
        }
        // The task's own progress can't be given children after the fact, and the tree may have
        // been going for a while, so it follows the tree.
        task.progress.totalUnitCount = Self.taskUnits
        let units = Int64(aggregate.fraction * Double(Self.taskUnits))
        if task.progress.completedUnitCount < units { task.progress.completedUnitCount = units }
    }

    /// With the lock held. At most once a second, or per percent.
    private func log(force: Bool, note: String?) {
        let fraction = aggregate.fraction
        let now = Date()
        if !force, let last = lastLogged, now.timeIntervalSince(last.at) < 1, fraction - last.fraction < 0.01 { return }
        guard force || lastLogged?.fraction != fraction else { return }
        lastLogged = (fraction, now)
        let treeValue = tree?.fractionCompleted ?? 0
        let suffix = (task != nil ? ", task attached" : "") + (note.map { ", " + $0 } ?? "")
        Log.continuedTask.info("Progress \(fraction, format: .fixed(precision: 3)) (tree \(treeValue, format: .fixed(precision: 3)))\(suffix, privacy: .public)")
    }
}

/// Where a part is in its photos: which one, and how far through its files. Reported to the run's
/// progress as photos done plus the part of the current one.
struct PhotoProgress: Sendable {
    let part: RunPlan.Part
    let index: Int
    let total: Int
    /// How many files the photo has.
    var files = 1

    /// `file` is the one being worked on, `fraction` how far through it.
    func report(file: Int = 0, fraction: Double = 0) {
        let through = (Double(file) + min(max(fraction, 0), 1)) / Double(max(files, 1))
        ContinuedRunTask.update(part, .work, completed: Double(index) + through, of: Double(total))
    }

    /// For a file's transfer: tells the run as bytes arrive and iCloud downloads progress.
    func transfer(of resource: PHAssetResource, file: Int, share: Double = 1) -> TransferReporter {
        TransferReporter(size: PhotoLibrary.fileSize(of: resource)) { fraction in
            self.report(file: file, fraction: fraction * share)
        }
    }
}

/// Collects a file's download and write progress, from whichever threads PhotoKit calls on.
final class TransferReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var transfer: TransferProgress
    private let report: @Sendable (Double) -> Void

    init(size: Int64?, report: @escaping @Sendable (Double) -> Void) {
        transfer = TransferProgress(size: size)
        self.report = report
    }

    func downloaded(_ fraction: Double) {
        let value = lock.withLock { () -> Double in
            transfer.download(fraction)
            return transfer.fraction()
        }
        report(value)
    }

    func wrote(_ bytes: Int64) {
        let value = lock.withLock { () -> Double in
            transfer.wrote(bytes)
            return transfer.fraction()
        }
        report(value)
    }
}
