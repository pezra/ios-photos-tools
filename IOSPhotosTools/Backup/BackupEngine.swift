import Foundation
import Photos
import S3Kit
import SyncKit
import UIKit

/// Finds assets that haven't been backed up, exports their files and hands them to the
/// background upload session.
actor BackupEngine {
    static let shared = BackupEngine()

    /// Presigned URLs (rather than header signatures, which expire after ~15 minutes) let the
    /// system start a queued upload whenever it likes.
    private let urlLifetime = 7 * 24 * 60 * 60
    /// How long staging waits for an upload slot when no upload has finished. They carry on in the
    /// background session either way, but some can be held back indefinitely, such as ones waiting
    /// for Wi-Fi, so the pass ends and the rest is staged once they've finished.
    private let slotStallLimit: Duration = .seconds(120)

    private let store = BackupStore.shared
    private let runner = PassRunner()
    /// Whether, once the uploads going now have finished, a pass is to stage what the last one
    /// left: refused names, files to send again, or photos there wasn't room for. Not after a pause.
    private var resumeOnSettle = false
    /// Whether the last pass stopped staging for want of room.
    private var leftPhotos = false

    nonisolated static func start() {
        Task { await shared.startPass() }
    }

    nonisolated static func stop() {
        Task { await shared.cancel() }
    }

    /// Listens for the uploads settling, for as long as the app runs. Call once, at launch.
    nonisolated static func watchUploads() {
        Task.detached(priority: .utility) {
            let tracker = SettleTracker(signal: UploadSession.shared.changes) { BackupStore.shared.count(.uploading) }
            while await tracker.nextSettle() {
                await shared.uploadsSettled()
            }
        }
    }

    /// Runs a pass (or joins the one in progress) and waits for it to finish. Cancelling the caller
    /// stops the pass.
    func run() async {
        await runner.run(onEnd: { Self.passEnded(cancelled: $0) }) { await self.performPass() }
    }

    func cancel() {
        resumeOnSettle = false
        runner.cancel()
    }

    /// "Forget backup history". Stops the pass first and waits for it, since forgetting a file
    /// between staging it and starting its upload would leave the upload with nothing to record it.
    /// A pass that was stopped starts again.
    func forgetHistory() async {
        let stopped = await runner.cancelAndWait()
        store.reset()
        Log.pass.info("Backup history forgotten")
        await MainActor.run { BackupStatus.shared.refreshCounts() }
        if stopped { startPass() }
    }

    @discardableResult
    private func startPass() -> Bool {
        runner.start(onEnd: { Self.passEnded(cancelled: $0) }) { await self.performPass() }.isNew
    }

    private static func passEnded(cancelled: Bool) {
        // Even if this pass couldn't back anything up: syncing can still work from the drive.
        if !cancelled { LibrarySyncEngine.start() }
    }

    private func performPass() async {
        resumeOnSettle = false
        guard let settings = SettingsStore.snapshot() else {
            await report(phase: "Storage not configured", running: false)
            return
        }
        guard PhotoLibrary.isAuthorized else {
            await report(phase: "Photo access needed", running: false)
            return
        }
        let client: S3Client
        do {
            client = try S3Client(config: settings.s3)
        } catch {
            await report(phase: "Invalid settings", running: false, error: error.localizedDescription)
            return
        }

        let session = settings.bucketSession()
        defer { session.finishTasksAndInvalidate() }

        await report(phase: "Checking library…", running: true, startingPass: true)
        // Before finding what's pending, since a new bucket has nothing in it yet.
        do {
            try StorageInventory.noticeBucket(client: client, prefix: settings.prefix)
        } catch {
            await report(phase: "Couldn't save the backup history", running: false, error: error.localizedDescription)
            return
        }
        await reconcileWithUploadSession()

        let pending = await LibrarySnapshot.current().pending(completed: store.completedAssets())
        store.forgetResourcesOfMissingAssets()
        await MainActor.run { BackupStatus.shared.refreshCounts() }

        var conditionalWrites = true
        // Names are checked against what's in the bucket so nothing is overwritten, so without a
        // listing nothing can safely be uploaded.
        if !pending.isEmpty {
            do {
                try await StorageInventory.prepareS3(client: client, prefix: settings.prefix, session: session)
                conditionalWrites = await StorageInventory.supportsConditionalWrites(client: client, prefix: settings.prefix, session: session)
            } catch let error as URLError where error.networkUnavailableReason == .cellular {
                await report(phase: "Waiting for Wi-Fi", running: false)
                return
            } catch {
                await report(phase: "Couldn't list the bucket", running: false,
                             error: "Backup needs s3:ListBucket and s3:GetObject as well as s3:PutObject. \(error.localizedDescription)")
                return
            }
        }

        var namingFailures = 0
        var namingError: String?
        var stoppedEarly = false
        for (index, asset) in pending.enumerated() {
            if Task.isCancelled { break }
            guard await roomToStage() else {
                stoppedEarly = !Task.isCancelled
                break
            }
            await report(phase: "Preparing \(index + 1) of \(pending.count)", running: true)
            if let error = await stage(asset, client: client, settings: settings, conditionalWrites: conditionalWrites) {
                namingFailures += 1
                namingError = error.localizedDescription
            }
            await StorageInventory.writeHandledPaths(toS3: client, prefix: settings.prefix, force: false, session: session)
        }

        // The pass ends once everything is staged. The uploads carry on in the background session.
        await StorageInventory.writeHandledPaths(toS3: client, prefix: settings.prefix, force: true, session: session)
        resumeOnSettle = !Task.isCancelled
        leftPhotos = stoppedEarly

        let failed = store.count(.failed) + namingFailures
        let uploading = store.count(.uploading)
        let phase = Task.isCancelled ? "Paused"
            : failed > 0 ? "Finished with \(failed) failed files"
            : uploading > 0 ? BackupStatus.waitingForUploads
            : "Up to date"
        await report(phase: phase, running: false, error: failed > 0 ? store.lastError() ?? namingError : nil, finished: !Task.isCancelled)
    }

    /// Returns an error if the asset's files couldn't be given paths, so it's tried again next pass.
    private func stage(_ listed: PHAsset, client: S3Client, settings: SettingsStore.Snapshot, conditionalWrites: Bool) async -> Error? {
        let assetID = listed.localIdentifier
        // The snapshot's copy may predate an edit; what's exported and recorded is the current one.
        guard let asset = PhotoLibrary.freshAsset(assetID) else { return nil }
        let modifiedAt = asset.modificationDate?.timeIntervalSince1970
        let resources: [(PHAssetResource, ResourceRow)]
        do {
            resources = try await BackupPaths.assign(asset, prefix: settings.prefix)
        } catch {
            return error
        }
        store.forgetMissingResources(forAsset: assetID, keeping: resources.map(\.1.id))
        guard !resources.isEmpty else {
            store.markAssetComplete(assetID, modifiedAt: modifiedAt)
            return nil
        }
        store.register(resources.map(\.1), assetID: assetID, assetModifiedAt: modifiedAt)
        #if DEBUG
        TestHooks.photoRegistered()
        #endif
        let existing = store.resources(forAsset: assetID)

        for (resource, row) in resources {
            if Task.isCancelled { return nil }
            let previous = existing[row.id]
            if previous?.state == .uploading { continue }
            // Originals never change, but an edited render keeps its name when re-edited, so it
            // is re-exported and compared by content.
            let isEdit = PhotoLibrary.editedTypes.contains(resource.type)
            if previous?.state == .done && !isEdit { continue }
            let inBucket = store.inventoryEntries(for: row.path).first { $0.source == .s3 }
            let plan = BucketUpload(previous: previous?.state, knownInBucket: store.isInBucket(row.path),
                                    inListing: inBucket != nil, isEdit: isEdit, conditionalWrites: conditionalWrites)
            let isOwn = plan.isOwn
            // Already at its own path in the bucket, as when reinstalling loses the upload history.
            if isOwn && !isEdit && inBucket != nil {
                store.markDone(row.id, path: row.path, sha256: previous?.sha256)
                continue
            }

            // Same name and size is the same file, so nothing is read from Photos or the bucket.
            if plan.compares, let inBucket {
                switch BackupPaths.match(resource, storedSizes: [inBucket.size]) {
                case .same:
                    store.markDone(row.id, path: row.path, sha256: nil)
                    continue
                case .different:
                    // Not this photo's own file (that was dealt with above), so it keeps the name.
                    store.retirePaths(forAsset: assetID)
                    return BackupPaths.Failure.nameTaken(row.path)
                case .compare:
                    break
                }
            }

            let stagedName = UUID().uuidString
            let file = Staging.url(for: stagedName)
            let sha256: String?
            do {
                try await PhotoLibrary.export(resource, to: file)
                sha256 = isEdit || inBucket != nil ? try Staging.sha256(of: file) : nil
            } catch {
                Staging.remove(stagedName)
                store.markFailed(row.id, error: "Couldn't read from photo library: \(error.localizedDescription)")
                continue
            }
            if previous?.state == .done && previous?.sha256 == sha256 {
                Staging.remove(stagedName)
                continue
            }
            if plan.compares, let inBucket, let sha256 {
                let matches: Bool?
                if let size = file.fileSize, size != inBucket.size {
                    matches = false
                } else {
                    matches = (try? await BackupPaths.sha256(ofExisting: [inBucket], path: row.path)).map { $0 == sha256 }
                }
                if matches == true {
                    Staging.remove(stagedName)
                    store.markDone(row.id, path: row.path, sha256: sha256)
                    continue
                }
                // Unless it's this photo's own older edit, which gets replaced, nothing is sent:
                // a different picture gets to keep the name.
                if !isOwn {
                    Staging.remove(stagedName)
                    if Task.isCancelled { return nil }
                    guard matches != nil else {
                        store.markFailed(row.id, error: BackupPaths.Failure.cannotCompare(row.path).localizedDescription)
                        continue
                    }
                    store.retirePaths(forAsset: assetID)
                    return BackupPaths.Failure.nameTaken(row.path)
                }
            }
            let url = client.presignedURL(method: "PUT", key: row.s3Key, expiresIn: urlLifetime)
            // The drive pass may have given the photo new paths since they were assigned here.
            guard store.markUploading(row.id, path: row.path, bucket: StorageInventory.identity(client: client, prefix: settings.prefix),
                                      stagedName: stagedName, sha256: sha256) else {
                Log.upload.info("Not uploading \(row.id, privacy: .public): its path changed while staging")
                Staging.remove(stagedName)
                continue
            }
            UploadSession.shared.upload(
                file: file,
                to: url,
                contentType: PhotoLibrary.contentType(of: resource),
                resourceID: row.id,
                allowCellular: settings.allowCellular,
                mustNotExist: plan.mustNotExist
            )
        }
        // Records the new modification date when nothing needed uploading.
        store.markAssetCompleteIfFinished(assetID)
        await MainActor.run { BackupStatus.shared.refreshCounts() }
        return nil
    }

    /// Whether there's room to stage another photo. In the foreground that's an upload slot, waited
    /// for. Uploads started in the background are paced by iOS, so there it's up to a disk budget,
    /// and the pass doesn't wait.
    private func roomToStage() async -> Bool {
        let background = await MainActor.run { UIApplication.shared.applicationState == .background }
        let room = StagingBudget.room(background: background, uploading: store.count(.uploading),
                                      stagedBytes: background ? Staging.size() : 0,
                                      availableBytes: background ? Staging.availableBytes() : nil)
        switch room {
        case .room:
            return true
        case .full:
            Log.upload.info("Staged as much as the background allows: the rest is left for later")
            return false
        case .waitForSlot:
            let store = store
            if await UploadSession.shared.changes.wait(until: { store.count(.uploading) < StagingBudget.foregroundSlots },
                                                       stallLimit: slotStallLimit) {
                return true
            }
            if !Task.isCancelled {
                Log.upload.info("No upload finished in \(self.slotStallLimit, privacy: .public): the rest is staged once they have")
            }
            return false
        }
    }

    /// The uploads have all finished. In the foreground, the handled paths are written if due, and a
    /// pass stages what the last one left. Not in the background, where this may be iOS waking the
    /// app briefly to deliver upload events: that's left for the next run.
    private func uploadsSettled() async {
        // A pass going now may still stage more, or have names refused while it runs, which no
        // later settle would pick up if its own uploads have all finished by the time it ends.
        await runner.join()
        guard store.count(.uploading) == 0 else { return }
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        guard active else {
            Log.upload.info("Uploads settled in the background: the rest is left for the next run")
            return
        }
        Log.upload.info("Uploads settled")
        if let settings = SettingsStore.snapshot(), let client = try? S3Client(config: settings.s3) {
            let session = settings.bucketSession()
            await StorageInventory.writeHandledPaths(toS3: client, prefix: settings.prefix, force: false, session: session)
            session.finishTasksAndInvalidate()
        }
        if resumeOnSettle && (leftPhotos || store.count(.pending) > 0) {
            Log.pass.info("Starting a pass for what the last one left")
            startPass()
        }
    }

    /// Resets resources marked as uploading whose task no longer exists (e.g. the app was
    /// reinstalled or the system dropped the task), and cleans up stray staged files.
    private func reconcileWithUploadSession() async {
        let inFlight = await UploadSession.shared.inFlight()
        var reset = false
        for resource in store.uploadingResources() where !inFlight.contains(resource.id) {
            Staging.remove(resource.stagedName)
            store.resetToPending(resource.id)
            reset = true
        }
        if reset { UploadSession.shared.changes.send() }
        Staging.removeOrphans(keeping: Set(store.uploadingResources().compactMap(\.stagedName)))
    }

    /// `startingPass` clears the previous pass's error, which otherwise lingers when that pass
    /// was paused.
    private func report(phase: String, running: Bool, error: String? = nil, finished: Bool = false, startingPass: Bool = false) async {
        Log.pass.log(phase: phase, of: "bucket", running: running, startingPass: startingPass)
        await MainActor.run {
            BackupStatus.shared.report(phase: phase, running: running, error: error, finished: finished, startingPass: startingPass)
        }
    }
}
