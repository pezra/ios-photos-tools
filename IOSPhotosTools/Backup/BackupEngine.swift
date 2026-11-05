import Foundation
import Photos
import S3Kit
import SyncKit

/// Finds assets that haven't been backed up, exports their files and hands them to the
/// background upload session.
actor BackupEngine {
    static let shared = BackupEngine()

    /// How many files may be exported and waiting to upload at once. Bounds disk usage.
    private let maxInFlight = 8
    /// Presigned URLs (rather than header signatures, which expire after ~15 minutes) let the
    /// system start a queued upload whenever it likes.
    private let urlLifetime = 7 * 24 * 60 * 60

    private let store = BackupStore.shared
    private var currentPass: Task<Void, Never>?

    nonisolated static func start() {
        Task { _ = await shared.startPass() }
    }

    nonisolated static func stop() {
        Task { await shared.cancel() }
    }

    /// Runs a pass (or joins the one in progress) and waits for it to finish.
    func run() async {
        await startPass().value
    }

    func cancel() {
        currentPass?.cancel()
    }

    private func startPass() -> Task<Void, Never> {
        if let currentPass { return currentPass }
        let pass = Task {
            await performPass()
            currentPass = nil
            // Even if this pass couldn't back anything up: syncing can still work from the drive.
            if !Task.isCancelled { LibrarySyncEngine.start() }
        }
        currentPass = pass
        return pass
    }

    /// `isRetry` is for the one extra pass given to uploads that have to be sent again.
    private func performPass(isRetry: Bool = false) async {
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

        await report(phase: "Checking library…", running: true)
        await reconcileWithUploadSession()

        let (pending, libraryIDs) = PhotoLibrary.pendingAssets(completed: store.completedAssets())
        store.setLibraryAssets(libraryIDs)
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
        for (index, asset) in pending.enumerated() {
            await waitForUploadSlot()
            if Task.isCancelled { break }
            await report(phase: "Preparing \(index + 1) of \(pending.count)", running: true)
            if let error = await stage(asset, client: client, settings: settings, conditionalWrites: conditionalWrites) {
                namingFailures += 1
                namingError = error.localizedDescription
            }
            await StorageInventory.writeHandledPaths(toS3: client, prefix: settings.prefix, force: false, session: session)
        }

        if !Task.isCancelled {
            await report(phase: "Uploading…", running: true)
            while !Task.isCancelled && store.count(.uploading) > 0 {
                try? await Task.sleep(for: .seconds(2))
            }
            // Uploads the bucket turned away because of the name.
            if !isRetry && store.count(.pending) > 0 {
                return await performPass(isRetry: true)
            }
        }
        await StorageInventory.writeHandledPaths(toS3: client, prefix: settings.prefix, force: true, session: session)

        let failed = store.count(.failed) + namingFailures
        let phase = Task.isCancelled ? "Paused" : failed > 0 ? "Finished with \(failed) failed files" : "Up to date"
        await report(phase: phase, running: false, error: failed > 0 ? store.lastError() ?? namingError : nil, finished: !Task.isCancelled)
    }

    /// Returns an error if the asset's files couldn't be given paths, so it's tried again next pass.
    private func stage(_ asset: PHAsset, client: S3Client, settings: SettingsStore.Snapshot, conditionalWrites: Bool) async -> Error? {
        let assetID = asset.localIdentifier
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
            // Having a path doesn't mean what's there is this photo's: it may have been chosen on
            // a pass to the drive, or before switching buckets.
            let isOwn = previous?.state == .done || store.isInBucket(row.path)
            // Already at its own path in the bucket, as when reinstalling loses the upload history.
            if isOwn && !isEdit && inBucket != nil {
                store.markDone(row.id)
                continue
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
            if previous?.state != .done, let inBucket, let sha256 {
                let matches: Bool?
                if let size = file.fileSize, size != inBucket.size {
                    matches = false
                } else {
                    matches = (try? await BackupPaths.sha256(ofExisting: [inBucket], path: row.path)).map { $0 == sha256 }
                }
                if matches == true {
                    Staging.remove(stagedName)
                    store.markDone(row.id, sha256: sha256)
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
            store.markUploading(row.id, stagedName: stagedName, sha256: sha256)
            UploadSession.shared.upload(
                file: file,
                to: url,
                contentType: PhotoLibrary.contentType(of: resource),
                resourceID: row.id,
                allowCellular: settings.allowCellular,
                mustNotExist: conditionalWrites && (!isEdit || !isOwn)
            )
        }
        // Records the new modification date when nothing needed uploading.
        store.markAssetCompleteIfFinished(assetID)
        await MainActor.run { BackupStatus.shared.refreshCounts() }
        return nil
    }

    private func waitForUploadSlot() async {
        while !Task.isCancelled && store.count(.uploading) >= maxInFlight {
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Resets resources marked as uploading whose task no longer exists (e.g. the app was
    /// reinstalled or the system dropped the task), and cleans up stray staged files.
    private func reconcileWithUploadSession() async {
        let liveTasks = Set(await UploadSession.shared.session.allTasks.compactMap(\.taskDescription))
        for resource in store.uploadingResources() where !liveTasks.contains(resource.id) {
            Staging.remove(resource.stagedName)
            store.resetToPending(resource.id)
        }
        Staging.removeOrphans(keeping: Set(store.uploadingResources().compactMap(\.stagedName)))
    }

    private func report(phase: String, running: Bool, error: String? = nil, finished: Bool = false) async {
        await MainActor.run {
            let status = BackupStatus.shared
            status.phase = phase
            status.isRunning = running
            if finished {
                status.lastFinished = Date()
                status.lastError = error
            } else if let error {
                status.lastError = error
            }
            status.refreshCounts()
        }
    }
}
