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
    private var currentPass: Task<Void, Never>?
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
    /// Set while the pass is syncing the phone's copies, which runs as its own pass.
    private var isSyncing = false

    /// Starts a pass if one isn't running. Called from the foreground, it also asks iOS to let the
    /// pass carry on when the app is closed.
    @MainActor static func start() {
        let inForeground = UIApplication.shared.applicationState == .active
        Task {
            if await shared.startPass().isNew, inForeground {
                await MainActor.run { DriveBackgroundTask.request() }
            }
        }
    }

    nonisolated static func stop() {
        Task { await shared.cancel() }
    }

    /// Runs a pass (or joins the one in progress) and waits for it to finish.
    func run() async {
        await startPass().task.value
    }

    func cancel() {
        currentPass?.cancel()
        if isSyncing { LibrarySyncEngine.stop() }
    }

    /// Shows the pass in progress under `task` and waits for it to end. Returns at once if that
    /// pass has already ended, rather than starting another, or if another task is showing it.
    func follow(_ task: BGContinuedProcessingTask) async {
        guard let currentPass, continuedTask == nil else { return }
        continuedTask = task
        showProgress()
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.nudgeInterval)
                nudge()
            }
        }
        await currentPass.value
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

    private func startPass() -> (task: Task<Void, Never>, isNew: Bool) {
        if let currentPass { return (currentPass, false) }
        let pass = Task {
            await performPass()
            heartbeat?.cancel()
            heartbeat = nil
            continuedTask = nil
            currentPass = nil
        }
        currentPass = pass
        return (pass, true)
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
        let (pending, libraryIDs) = PhotoLibrary.pendingAssets(completed: store.completedDriveAssets(driveID: driveID))
        store.setLibraryAssets(libraryIDs)
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
            StorageInventory.writeHandledPaths(toDrive: root, driveID: driveID, force: false)
            guard let error else { continue }
            if (try? root.checkResourceIsReachable()) != true {
                disconnected = true
                break
            }
            failed += 1
            lastError = error.localizedDescription
        }
        setProgress(pending.count, of: pending.count)
        if !disconnected {
            StorageInventory.writeHandledPaths(toDrive: root, driveID: driveID, force: true)
        }

        let phase = disconnected ? "Drive disconnected"
            : Task.isCancelled ? "Paused"
            : failed > 0 ? "Finished with \(failed) items not copied"
            : "Up to date"
        await report(phase: phase, running: false, error: lastError, finished: !Task.isCancelled && !disconnected)

        if !Task.isCancelled && !disconnected {
            isSyncing = true
            await LibrarySyncEngine.shared.run { phase, done, total in
                Task { await DriveBackupEngine.shared.showSyncProgress(phase, done: done, total: total) }
            }
            isSyncing = false
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
    private func copy(_ asset: PHAsset, to root: URL, driveID: String) async -> Error? {
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
                    store.markOnDrive(row.path)
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
                store.markOnDrive(row.path)
            } catch {
                try? fm.removeItem(at: partial)
                // Pausing interrupts the file being copied; that isn't a failure.
                if Task.isCancelled { return nil }
                firstError = firstError ?? error
            }
        }
        // The drive may have been switched or removed in settings since the pass started.
        if firstError == nil && !Task.isCancelled && DriveDestination.id == driveID {
            store.markDriveAssetComplete(asset.localIdentifier, driveID: driveID,
                                         modifiedAt: asset.modificationDate?.timeIntervalSince1970)
        }
        return firstError
    }

    /// `startingPass` clears the previous pass's error, which otherwise lingers when that pass
    /// was paused or the drive was unplugged.
    private func report(phase: String, running: Bool, error: String? = nil, finished: Bool = false, startingPass: Bool = false) async {
        continuedTask?.updateTitle(DriveBackgroundTask.title, subtitle: phase)
        await MainActor.run {
            let status = DriveStatus.shared
            status.phase = phase
            status.isRunning = running
            if startingPass {
                status.lastError = nil
            } else if finished {
                status.lastFinished = Date()
                status.lastError = error
            } else if let error {
                status.lastError = error
            }
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
            task.expirationHandler = {
                DriveBackupEngine.stop()
                LibrarySyncEngine.stop()
            }
            Task {
                await DriveBackupEngine.shared.follow(task)
                task.setTaskCompleted(success: true)
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Couldn't continue drive backup in the background: \(error)")
        }
    }
}
