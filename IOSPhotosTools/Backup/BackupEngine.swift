import Foundation
import Photos
import S3Kit

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
        }
        currentPass = pass
        return pass
    }

    private func performPass() async {
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

        await report(phase: "Checking library…", running: true)
        await reconcileWithUploadSession()

        let (pending, libraryIDs) = PhotoLibrary.pendingAssets(completed: store.completedAssets())
        store.setLibraryAssets(libraryIDs)
        await MainActor.run { BackupStatus.shared.refreshCounts() }

        for (index, asset) in pending.enumerated() {
            await waitForUploadSlot()
            if Task.isCancelled { break }
            await report(phase: "Preparing \(index + 1) of \(pending.count)", running: true)
            await stage(asset, client: client, settings: settings)
        }

        if !Task.isCancelled {
            await report(phase: "Uploading…", running: true)
            while !Task.isCancelled && store.count(.uploading) > 0 {
                try? await Task.sleep(for: .seconds(2))
            }
        }

        let failed = store.count(.failed)
        let phase = Task.isCancelled ? "Paused" : failed > 0 ? "Finished with \(failed) failed files" : "Up to date"
        await report(phase: phase, running: false, error: failed > 0 ? store.lastError() : nil, finished: !Task.isCancelled)
    }

    private func stage(_ asset: PHAsset, client: S3Client, settings: SettingsStore.Snapshot) async {
        let assetID = asset.localIdentifier
        let modifiedAt = asset.modificationDate?.timeIntervalSince1970
        let resources = PhotoLibrary.backupResources(for: asset, prefix: settings.prefix)
        guard !resources.isEmpty else {
            store.markAssetComplete(assetID, modifiedAt: modifiedAt)
            return
        }
        store.register(resources.map(\.1), assetID: assetID, assetModifiedAt: modifiedAt)
        let existing = store.resources(forAsset: assetID)

        for (resource, row) in resources {
            if Task.isCancelled { return }
            let previous = existing[row.id]
            if previous?.state == .uploading { continue }
            // Originals never change, but an edited render keeps its name when re-edited, so it
            // is re-exported and compared by content.
            let isEdit = PhotoLibrary.editedTypes.contains(resource.type)
            if previous?.state == .done && !isEdit { continue }

            let stagedName = UUID().uuidString
            let file = Staging.url(for: stagedName)
            let sha256: String?
            do {
                try await PhotoLibrary.export(resource, to: file)
                sha256 = isEdit ? try Staging.sha256(of: file) : nil
            } catch {
                Staging.remove(stagedName)
                store.markFailed(row.id, error: "Couldn't read from photo library: \(error.localizedDescription)")
                continue
            }
            if previous?.state == .done && previous?.sha256 == sha256 {
                Staging.remove(stagedName)
                continue
            }
            let url = client.presignedURL(method: "PUT", key: row.s3Key, expiresIn: urlLifetime)
            store.markUploading(row.id, stagedName: stagedName, sha256: sha256)
            UploadSession.shared.upload(
                file: file,
                to: url,
                contentType: PhotoLibrary.contentType(of: resource),
                resourceID: row.id,
                allowCellular: settings.allowCellular
            )
        }
        // Records the new modification date when nothing needed uploading.
        store.markAssetCompleteIfFinished(assetID)
        await MainActor.run { BackupStatus.shared.refreshCounts() }
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
