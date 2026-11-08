import Foundation
import Photos
import S3Kit
import SyncKit

/// Copies the photo library to the folder chosen on a USB drive, using the same layout as the
/// bucket (`<year>/<file>`). A part of `BackupRun`.
///
/// Files are written straight to the drive, so there's no staging or upload queue: a pass is done
/// when it returns. Files are written under a temporary name and renamed when complete, so a file
/// that exists on the drive is whole.
actor DriveBackupEngine {
    static let shared = DriveBackupEngine()

    private let store = BackupStore.shared
    private let runner = PassRunner()

    /// Pauses the pass. The rest of the run carries on.
    nonisolated static func stop() {
        Task { await shared.cancel() }
    }

    /// Runs a pass as part of `run` (or joins the one in progress) and waits for it to finish.
    /// Cancelling the caller stops the pass.
    func run(in run: Run) async {
        await runner.run { await self.performPass(run) }
    }

    func cancel() {
        runner.cancel()
    }

    private func performPass(_ run: Run) async {
        guard let driveID = DriveDestination.id else {
            return await report(phase: "No drive set up", running: false)
        }
        guard PhotoLibrary.isAuthorized else {
            return await report(phase: "Photo access needed", running: false)
        }
        // A normal outcome, in the background too: a locked phone may not see the drive.
        guard let root = DriveDestination.open() else {
            return await report(phase: "Drive not connected", running: false)
        }
        defer { DriveDestination.close(root) }

        await report(phase: "Checking library…", running: true, startingPass: true)
        let pending = await LibrarySnapshot.current().pending(completed: store.completedDriveAssets(driveID: driveID))
        ContinuedRunTask.progress(.drive, done: 0, of: pending.count)

        // Names are checked against what's on the drive and in the bucket so nothing is overwritten,
        // and the sync needs the drive's listing too.
        do {
            try await prepare(run, root: root, driveID: driveID, pending: pending.count)
        } catch {
            return await report(phase: Task.isCancelled ? BackupRun.pausedPhase : "Couldn't check what's in storage", running: false,
                                error: Task.isCancelled ? nil : error.localizedDescription)
        }
        await run.barrier.ready(.drive)

        var failed = 0
        var lastError: String?
        var disconnected = false
        for (index, asset) in pending.enumerated() {
            if Task.isCancelled { break }
            ContinuedRunTask.progress(.drive, done: index, of: pending.count)
            await report(phase: "Copying \(index + 1) of \(pending.count)", running: true)
            let error = await run.photoLock.withLock(asset.localIdentifier) {
                await copy(asset, to: root, driveID: driveID)
            }
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
        ContinuedRunTask.progress(.drive, done: pending.count, of: pending.count)
        if !disconnected {
            await StorageInventory.writeHandledPaths(toDrive: root, driveID: driveID, force: true)
        }

        let phase = disconnected ? "Drive disconnected"
            : Task.isCancelled ? BackupRun.pausedPhase
            : failed > 0 ? "Finished with \(failed) items not copied"
            : "Up to date"
        await report(phase: phase, running: false, error: lastError, finished: !Task.isCancelled && !disconnected)
    }

    /// Off the actor because walking the drive takes a while, and pausing has to be able to get through.
    private nonisolated func prepare(_ run: Run, root: URL, driveID: String, pending: Int) async throws {
        let needs = RunPlan.needs(.drive, pending: pending, parts: run.plannedParts, setup: run.setup)
        if needs.drive {
            await showListing("Reading drive…")
            try await run.preparation.prepareDrive(root: root, driveID: driveID) { found in
                await self.showListing("Reading drive… \(found.formatted()) files")
            }
        }
        guard needs.bucket, let settings = SettingsStore.snapshot(), let client = try? S3Client(config: settings.s3) else { return }
        let session = settings.bucketSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            try await run.preparation.prepareBucket(client: client, prefix: settings.prefix, session: session) { listed in
                await self.showListing("Listing bucket… \(listed.formatted()) files")
            }
        } catch {
            // The bucket's last listing will do if it can't be reached now, but there must be one.
            guard !Task.isCancelled, StorageInventory.hasListedS3(client: client, prefix: settings.prefix) else { throw error }
            Log.listing.info("Couldn't list the bucket, so the drive goes by its last listing: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func showListing(_ phase: String) async {
        ContinuedRunTask.listingStep(.drive, phase: phase)
        await report(phase: phase, running: true)
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
        ContinuedRunTask.phase(.drive, phase)
        await MainActor.run {
            DriveStatus.shared.report(phase: phase, running: running, error: error, finished: finished, startingPass: startingPass)
            BackupStatus.shared.refreshCounts()
        }
    }
}
