import BackgroundTasks
import Foundation
import Photos
import S3Kit
import SyncKit
import UIKit

/// Copies the photo library to the folder chosen on a USB drive, using the same layout as the
/// bucket (`<year>/<file>`).
///
/// Files are written straight to the drive, so there's no staging or upload queue: a pass is done
/// when it returns. Files are written under a temporary name and renamed when complete, so a file
/// that exists on the drive is whole. A pass ends by syncing the phone's low-res copies.
actor DriveBackupEngine {
    static let shared = DriveBackupEngine()

    private let store = BackupStore.shared
    private let runner = PassRunner()
    /// Set while iOS is letting the pass continue in the background; shows progress to the user.
    private var continuedTask: BGContinuedProcessingTask?
    private var progress = (done: 0, total: 0)
    /// Steps of reading the drive and listing the bucket this pass, which count as work done.
    private var listingSteps = 0
    /// iOS ends a continued task whose progress hasn't moved for a while (about 30 seconds, going
    /// by other developers' reports). Copying a big video, or downloading it from iCloud first, can
    /// take longer than that, so while there's a task its progress is nudged along within the
    /// current step. A step that outlasts the nudges is left to look stalled.
    private var nudges = 0
    private var heartbeat: Task<Void, Never>?
    private static let unitsPerStep: Int64 = 100
    private static let nudgeInterval: Duration = .seconds(5)

    /// Starts a pass if one isn't running. Called from the foreground, it also asks iOS to let the
    /// pass carry on when the app is closed.
    @MainActor static func start() {
        let inForeground = UIApplication.shared.applicationState == .active
        Task {
            if await shared.startPass(), inForeground {
                await MainActor.run { DriveBackgroundTask.request() }
            }
        }
    }

    nonisolated static func stop() {
        Task { await shared.cancel() }
    }

    /// Runs a pass (or joins the one in progress) and waits for it to finish. Cancelling the caller
    /// stops the pass.
    func run() async {
        await runner.run(onEnd: { _ in await self.passEnded() }) { await self.performPass() }
    }

    func cancel() {
        runner.cancel()
    }

    /// Shows the pass in progress under `task` and waits for it to end. Returns at once if that
    /// pass has already ended, rather than starting another, or if another task is showing it.
    func follow(_ task: BGContinuedProcessingTask) async {
        guard runner.isRunning, continuedTask == nil else { return }
        continuedTask = task
        showProgress()
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.nudgeInterval)
                nudge()
            }
        }
        await runner.join()
    }

    private func setProgress(_ done: Int, of total: Int) {
        progress = (done, total)
        nudges = 0
        showProgress()
    }

    private func nudge() {
        guard nudges < Self.unitsPerStep - 1 else { return }
        nudges += 1
        showProgress()
    }

    /// The extra step in the total leaves room for nudges once everything's counted as done.
    private func showProgress() {
        continuedTask?.progress.totalUnitCount = Int64(listingSteps + progress.total + 1) * Self.unitsPerStep
        continuedTask?.progress.completedUnitCount = Int64(listingSteps + progress.done) * Self.unitsPerStep + Int64(nudges)
    }

    private func showListing(_ phase: String) async {
        listingSteps += 1
        setProgress(progress.done, of: progress.total)
        await report(phase: phase, running: true)
    }

    /// Whether this started a pass, rather than joining the one in progress.
    private func startPass() -> Bool {
        runner.start(onEnd: { _ in await self.passEnded() }) { await self.performPass() }.isNew
    }

    private func passEnded() {
        heartbeat?.cancel()
        heartbeat = nil
        continuedTask = nil
    }

    private func performPass() async {
        guard let driveID = DriveDestination.id else {
            return await report(phase: "No drive set up", running: false)
        }
        guard PhotoLibrary.isAuthorized else {
            return await report(phase: "Photo access needed", running: false)
        }
        guard let root = DriveDestination.open() else {
            return await report(phase: "Drive not connected", running: false)
        }
        defer { DriveDestination.close(root) }

        await report(phase: "Checking library…", running: true, startingPass: true)
        let pending = await LibrarySnapshot.current().pending(completed: store.completedDriveAssets(driveID: driveID))
        listingSteps = 0
        setProgress(0, of: pending.count)

        // Names are checked against what's on the drive and in the bucket so nothing is overwritten,
        // and the sync at the end needs the drive's listing too.
        if !pending.isEmpty || SettingsStore.syncEnabled {
            do {
                try await prepareInventory(root: root, driveID: driveID, includingBucket: !pending.isEmpty)
            } catch {
                return await report(phase: Task.isCancelled ? "Paused" : "Couldn't check what's in storage", running: false,
                                    error: Task.isCancelled ? nil : error.localizedDescription)
            }
        }

        var failed = 0
        var lastError: String?
        var disconnected = false
        for (index, asset) in pending.enumerated() {
            if Task.isCancelled { break }
            setProgress(index, of: pending.count)
            await report(phase: "Copying \(index + 1) of \(pending.count)", running: true)
            let error = await copy(asset, to: root, driveID: driveID)
            await StorageInventory.writeHandledPaths(toDrive: root, driveID: driveID, force: false)
            guard let error else { continue }
            if (try? root.checkResourceIsReachable()) != true {
                disconnected = true
                break
            }
            failed += 1
            lastError = error.localizedDescription
            Log.pass.error("drive: \(asset.localIdentifier, privacy: .public) not copied: \(error.localizedDescription, privacy: .public)")
        }
        setProgress(pending.count, of: pending.count)
        if !disconnected {
            await StorageInventory.writeHandledPaths(toDrive: root, driveID: driveID, force: true)
        }

        let phase = disconnected ? "Drive disconnected"
            : Task.isCancelled ? "Paused"
            : failed > 0 ? "Finished with \(failed) items not copied"
            : "Up to date"
        await report(phase: phase, running: false, error: lastError, finished: !Task.isCancelled && !disconnected)

        // Pausing this pass stops the sync too, since it's waited for here.
        if !Task.isCancelled && !disconnected {
            await LibrarySyncEngine.shared.run { phase, done, total in
                Task { await DriveBackupEngine.shared.showSyncProgress(phase, done: done, total: total) }
            }
        }
    }

    private func showSyncProgress(_ phase: String, done: Int, total: Int) {
        continuedTask?.updateTitle(DriveBackgroundTask.syncTitle, subtitle: phase)
        listingSteps = 0
        setProgress(done, of: total)
    }

    /// Off the actor because walking the drive takes a while, and pausing has to be able to get through.
    private nonisolated func prepareInventory(root: URL, driveID: String, includingBucket: Bool) async throws {
        await showListing("Reading drive…")
        try await StorageInventory.prepareDrive(root: root, driveID: driveID) { found in
            await self.showListing("Reading drive… \(found.formatted()) files")
        }
        // The bucket's last listing will do if it can't be reached now, but there must be one.
        guard includingBucket, let settings = SettingsStore.snapshot(), let client = try? S3Client(config: settings.s3),
              !StorageInventory.hasListedS3(client: client, prefix: settings.prefix)
        else { return }
        let session = settings.bucketSession()
        defer { session.finishTasksAndInvalidate() }
        await showListing("Listing bucket…")
        try await StorageInventory.prepareS3(client: client, prefix: settings.prefix, session: session) { listed in
            await self.showListing("Listing bucket… \(listed.formatted()) files")
        }
    }

    /// Whether the file at `existing` has the same contents as `resource`.
    private func isSameFile(_ resource: PHAssetResource, existing: URL) async throws -> Bool {
        switch BackupPaths.match(resource, storedSizes: existing.fileSize.map { [$0] } ?? []) {
        case .same: return true
        case .different: return false
        case .compare: break
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try await PhotoLibrary.stream(resource, to: copy)
        // Saves reading the whole file from the drive. A size that can't be read is left for
        // hashing to report, since it doesn't mean the files differ.
        if let size = copy.fileSize, let existingSize = existing.fileSize, size != existingSize { return false }
        return try Staging.sha256(of: copy) == Staging.sha256(of: existing)
    }

    /// Copies the asset's files that aren't on the drive yet, plus its edited versions (which keep
    /// their name when re-edited). Returns the first error, if any.
    private func copy(_ listed: PHAsset, to root: URL, driveID: String) async -> Error? {
        // The snapshot's copy may predate an edit; what's copied and recorded is the current one.
        guard let asset = PhotoLibrary.freshAsset(listed.localIdentifier) else { return nil }
        let fm = FileManager.default
        var firstError: Error?
        let resources: [(PHAssetResource, ResourceRow)]
        do {
            resources = try await BackupPaths.assign(asset, prefix: "")
        } catch {
            return error
        }
        for (resource, row) in resources {
            if Task.isCancelled { return nil }
            let destination = root.appending(path: row.path)
            let isEdit = PhotoLibrary.editedTypes.contains(resource.type)
            let isOwn = store.isOnDrive(row.path)
            if fm.fileExists(atPath: destination.path) && isOwn && !isEdit { continue }
            // Never overwrites: the path may have been chosen while the drive was away. Only an
            // edit known to be this photo's own gets replaced.
            if fm.fileExists(atPath: destination.path) && !isOwn {
                do {
                    guard try await isSameFile(resource, existing: destination) else {
                        store.retirePaths(forAsset: asset.localIdentifier)
                        return BackupPaths.Failure.nameTaken(row.path)
                    }
                    store.markOnDrive(row.path, resource: row.id)
                } catch {
                    if Task.isCancelled { return nil }
                    firstError = firstError ?? error
                }
                continue
            }

            let partial = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).partial")
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await PhotoLibrary.stream(resource, to: partial)
                // rename(2) replaces an existing edit in one step.
                guard rename(partial.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                store.markOnDrive(row.path, resource: row.id)
            } catch {
                try? fm.removeItem(at: partial)
                // Pausing interrupts the file being copied; that isn't a failure.
                if Task.isCancelled { return nil }
                firstError = firstError ?? error
            }
        }
        // The drive may have been switched or removed in settings since the pass started. Not
        // complete either if the bucket pass gave the photo new paths meanwhile: it's copied to
        // those next time.
        if firstError == nil && !Task.isCancelled && DriveDestination.id == driveID {
            store.markDriveAssetComplete(asset.localIdentifier, driveID: driveID,
                                         modifiedAt: asset.modificationDate?.timeIntervalSince1970, files: resources.map(\.1))
        }
        return firstError
    }

    /// `startingPass` clears the previous pass's error, which otherwise lingers when that pass
    /// was paused or the drive was unplugged.
    private func report(phase: String, running: Bool, error: String? = nil, finished: Bool = false, startingPass: Bool = false) async {
        Log.pass.log(phase: phase, of: "drive", running: running, startingPass: startingPass)
        continuedTask?.updateTitle(DriveBackgroundTask.title, subtitle: phase)
        await MainActor.run {
            DriveStatus.shared.report(phase: phase, running: running, error: error, finished: finished, startingPass: startingPass)
            BackupStatus.shared.refreshCounts()
        }
    }
}

/// Lets a drive backup started in the foreground keep running after the app is closed, with its
/// progress shown by the system.
enum DriveBackgroundTask {
    static let title = "Backing up to USB drive"
    static let syncTitle = "Syncing pictures to this phone"
    /// `org.barelyenough.ios-photos-tools.drive.*` is permitted in Info.plist.
    private static let identifierPrefix = "org.barelyenough.ios-photos-tools.drive."

    /// Must be called while the app is in the foreground.
    @MainActor static func request() {
        // Continued-processing handlers can be registered after launch, but only once per
        // identifier, so each request gets its own.
        let identifier = identifierPrefix + UUID().uuidString
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            Log.continuedTask.info("Continued task started")
            task.expirationHandler = {
                Log.continuedTask.info("Continued task expired or stopped")
                DriveBackupEngine.stop()
                LibrarySyncEngine.stop()
            }
            Task {
                await DriveBackupEngine.shared.follow(task)
                // Even when it expired: the handler can't tell iOS cutting it short from the user
                // stopping it, and failure would show a "failed" notification for a stop they chose.
                // A pass cut short carries on next time anyway.
                task.setTaskCompleted(success: true)
                Log.continuedTask.info("Continued task completed")
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.continuedTask.info("Continued task requested")
        } catch {
            Log.continuedTask.error("Couldn't continue drive backup in the background: \(error, privacy: .public)")
        }
    }
}
