import BackgroundTasks
import Foundation
import Photos
import UIKit

/// Copies the photo library to the folder chosen on a USB drive, using the same layout as the
/// bucket (`<year>/<month>/<asset-uuid>/<file>`).
///
/// Files are written straight to the drive, so there's no staging or upload queue: a pass is done
/// when it returns. Files are written under a temporary name and renamed when complete, so a file
/// that exists on the drive is whole.
actor DriveBackupEngine {
    static let shared = DriveBackupEngine()

    private let store = BackupStore.shared
    private var currentPass: Task<Void, Never>?
    /// Set while iOS is letting the pass continue in the background; shows progress to the user.
    private var continuedTask: BGContinuedProcessingTask?
    private var progress = (done: 0, total: 0)

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
    }

    func attach(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        setProgress(progress.done, of: progress.total)
    }

    private func setProgress(_ done: Int, of total: Int) {
        progress = (done, total)
        continuedTask?.progress.totalUnitCount = Int64(total)
        continuedTask?.progress.completedUnitCount = Int64(done)
    }

    private func startPass() -> (task: Task<Void, Never>, isNew: Bool) {
        if let currentPass { return (currentPass, false) }
        let pass = Task {
            await performPass()
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
        let completed = store.completedDriveAssets(driveID: driveID)
        var pending: [PHAsset] = []
        PhotoLibrary.fetchAllAssets().enumerateObjects { asset, _, _ in
            guard let copiedAt = completed[asset.localIdentifier] else { return pending.append(asset) }
            if let copiedAt, let modified = asset.modificationDate?.timeIntervalSince1970, modified <= copiedAt { return }
            pending.append(asset)
        }
        setProgress(0, of: pending.count)

        var failed = 0
        var lastError: String?
        var disconnected = false
        for (index, asset) in pending.enumerated() {
            if Task.isCancelled { break }
            setProgress(index, of: pending.count)
            await report(phase: "Copying \(index + 1) of \(pending.count)", running: true)
            guard let error = await copy(asset, to: root, driveID: driveID) else { continue }
            if (try? root.checkResourceIsReachable()) != true {
                disconnected = true
                break
            }
            failed += 1
            lastError = error.localizedDescription
        }
        setProgress(pending.count, of: pending.count)

        let phase = disconnected ? "Drive disconnected"
            : Task.isCancelled ? "Paused"
            : failed > 0 ? "Finished with \(failed) items not copied"
            : "Up to date"
        await report(phase: phase, running: false, error: lastError, finished: !Task.isCancelled && !disconnected)
        continuedTask = nil
    }

    /// Copies the asset's files that aren't on the drive yet, plus its edited versions (which keep
    /// their name when re-edited). Returns the first error, if any.
    private func copy(_ asset: PHAsset, to root: URL, driveID: String) async -> Error? {
        let fm = FileManager.default
        var firstError: Error?
        for (resource, row) in PhotoLibrary.backupResources(for: asset, prefix: "") {
            if Task.isCancelled { return nil }
            let destination = root.appending(path: row.s3Key)
            let isEdit = PhotoLibrary.editedTypes.contains(resource.type)
            if !isEdit && fm.fileExists(atPath: destination.path) { continue }

            let partial = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).partial")
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await PhotoLibrary.stream(resource, to: partial)
                // rename(2) replaces an existing edit in one step.
                guard rename(partial.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                try? fm.removeItem(at: partial)
                firstError = firstError ?? error
            }
        }
        if firstError == nil && !Task.isCancelled {
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
    /// `org.barelyenough.ios-photos-tools.drive.*` is permitted in Info.plist.
    private static let identifierPrefix = "org.barelyenough.ios-photos-tools.drive."

    /// Must be called while the app is in the foreground.
    @MainActor static func request() {
        // Continued-processing handlers can be registered after launch, but only once per
        // identifier, so each request gets its own.
        let identifier = identifierPrefix + UUID().uuidString
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
            task.expirationHandler = { DriveBackupEngine.stop() }
            Task {
                await DriveBackupEngine.shared.attach(task)
                await DriveBackupEngine.shared.run()
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
