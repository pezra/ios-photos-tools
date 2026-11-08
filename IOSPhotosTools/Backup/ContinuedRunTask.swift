import BackgroundTasks
import Foundation
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
    /// Steps of reading the drive and listing the bucket this run, which count as work done.
    private var listingSteps = 0
    private var items: [RunPlan.Part: (done: Int, total: Int)] = [:]
    /// iOS ends a continued task whose progress hasn't moved for a while (about 30 seconds, going
    /// by other developers' reports). Copying a big video, or downloading it from iCloud first, can
    /// take longer than that, so while there's a task its progress is nudged along within the
    /// current step. A step that outlasts the nudges is left to look stalled.
    private var nudges: Int64 = 0
    private var heartbeat: Task<Void, Never>?
    private static let unitsPerStep: Int64 = 100
    private static let nudgeInterval: Duration = .seconds(5)

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

    // MARK: - The run's progress

    static func runStarted() {
        shared.lock.withLock {
            shared.listingSteps = 0
            shared.items = [:]
            shared.nudges = 0
        }
    }

    /// A task requested for a run that ended before iOS handed it over is completed when it arrives.
    /// Until then a tap may request another.
    static func runEnded() {
        shared.lock.withLock {
            if case .requested = shared.state { shared.state = .none }
        }
    }

    /// A step of reading the drive or listing the bucket.
    static func listingStep(_ part: RunPlan.Part, phase: String) {
        shared.lock.withLock {
            shared.listingSteps += 1
            shared.nudges = 0
            shared.show(part, phase: phase)
        }
    }

    /// How far a part has got through its photos.
    static func progress(_ part: RunPlan.Part, done: Int, of total: Int, phase: String? = nil) {
        shared.lock.withLock {
            shared.items[part] = (done, total)
            shared.nudges = 0
            shared.show(part, phase: phase)
        }
    }

    static func phase(_ part: RunPlan.Part, _ phase: String) {
        shared.lock.withLock { shared.show(part, phase: phase) }
    }

    private func nudge() {
        lock.withLock {
            guard nudges < Self.unitsPerStep - 1 else { return }
            nudges += 1
            show()
        }
    }

    /// With the lock held. The extra step in the total leaves room for nudges once everything's
    /// counted as done.
    private func show(_ part: RunPlan.Part? = nil, phase: String? = nil) {
        guard let task else { return }
        if let phase, let part {
            task.updateTitle(part == .sync ? Self.syncTitle : Self.backupTitle, subtitle: phase)
        }
        let done = items.values.reduce(0) { $0 + $1.done }
        let total = items.values.reduce(0) { $0 + $1.total }
        task.progress.totalUnitCount = Int64(listingSteps + total + 1) * Self.unitsPerStep
        task.progress.completedUnitCount = Int64(listingSteps + done) * Self.unitsPerStep + nudges
    }
}
