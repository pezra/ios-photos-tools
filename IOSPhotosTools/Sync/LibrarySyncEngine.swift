import CoreLocation
import Foundation
import Photos
import S3Kit
import SyncKit
import UniformTypeIdentifiers

/// Keeps a low-resolution copy of every picture in storage in the Photos library.
///
/// Only adds: a picture is imported once and then left alone. A path that's been backed up from
/// this phone or imported is never imported again, even if the photo has since been deleted.
actor LibrarySyncEngine {
    static let shared = LibrarySyncEngine()

    static let albumTitle = "Drive Library"
    static let undatedAlbumTitle = "Undated"
    /// Rough size of a copy, from a sample of the library, for estimates.
    static let estimatedBytesPerPicture: Int64 = 290_000

    private let store = BackupStore.shared
    private let batchSize = 20
    private let minimumFreeBytes: Int64 = 10_000_000_000
    private var currentPass: Task<Void, Never>?
    /// Lets a pass running under a system background task show its progress there.
    private var progressHandler: (@Sendable (String, Int, Int) -> Void)?

    nonisolated static func start() {
        Task { _ = await shared.startPass() }
    }

    nonisolated static func stop() {
        Task { await shared.cancel() }
    }

    /// Runs a pass (or joins the one in progress) and waits for it to finish.
    func run(onProgress: (@Sendable (String, Int, Int) -> Void)? = nil) async {
        if let onProgress { progressHandler = onProgress }
        await startPass().value
        progressHandler = nil
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

    // MARK: - Preview

    /// How many pictures the first sync would import, shown before it's started.
    func countPending() async throws -> Int {
        let sources = Sources.open()
        defer { sources.close() }
        guard sources.isAvailable else { throw PreviewError.noSource }
        let reachedS3 = try await prepareInventory(sources)
        if sources.drive == nil && !reachedS3 { throw PreviewError.noSource }
        try await scanForImportsIfNeeded()
        return candidates(sources: sources, reachedS3: reachedS3).count
    }

    enum PreviewError: Error, LocalizedError {
        case noSource

        var errorDescription: String? {
            "Plug in the drive or set up the bucket first."
        }
    }

    // MARK: - The pass

    private func performPass() async {
        guard SettingsStore.syncEnabled else { return }
        guard PhotoLibrary.hasFullAccess else {
            return await report(phase: "Needs full photo access", running: false)
        }
        let sources = Sources.open()
        defer { sources.close() }
        guard sources.isAvailable else {
            return await report(phase: "Waiting for the drive or bucket", running: false)
        }

        await report(phase: "Checking storage…", running: true, startingPass: true)
        let reachedS3: Bool
        do {
            reachedS3 = try await prepareInventory(sources)
            await report(phase: "Checking library…", running: true)
            try await scanForImportsIfNeeded()
        } catch {
            return await report(phase: Task.isCancelled ? "Paused" : "Couldn't check storage", running: false,
                                error: Task.isCancelled ? nil : error.localizedDescription)
        }
        guard sources.drive != nil || reachedS3 else {
            return await report(phase: "Waiting for the drive or bucket", running: false)
        }

        let pending = candidates(sources: sources, reachedS3: reachedS3)
        let album: Albums
        do {
            album = try await Albums.findOrCreate()
        } catch {
            return await report(phase: "Couldn't create the album", running: false, error: error.localizedDescription)
        }

        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("SyncImports", isDirectory: true)
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var imported = 0
        var failed = 0
        var lastError: String?
        var stoppedFor: String?

        batches: for start in stride(from: 0, to: pending.count, by: batchSize) {
            if Task.isCancelled { break }
            guard hasRoom else {
                stoppedFor = "Paused: less than 10 GB free"
                break
            }
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            await report(phase: "Importing \(start + 1) of \(pending.count)", running: true, done: start, total: pending.count)

            let prepared = await prepare(batch, sources: sources, workspace: workspace)
            if Task.isCancelled { break }
            if let root = sources.drive, (try? root.checkResourceIsReachable()) != true {
                stoppedFor = "Drive disconnected"
                break batches
            }

            var ready: [Prepared] = []
            for (item, result) in prepared {
                switch result {
                case let .success(value): ready.append(value)
                case let .failure(error):
                    failed += 1
                    lastError = "\(item.path): \(error.localizedDescription)"
                }
            }
            let outcome = await importToLibrary(ready, albums: album)
            imported += outcome.imported
            failed += outcome.failed
            lastError = outcome.lastError ?? lastError
            for item in ready { try? FileManager.default.removeItem(at: item.output.file) }

            await writeHandledPaths(sources, force: false)
            await refreshCounts(remaining: pending.count - start - batch.count, failed: failed)
        }

        await writeHandledPaths(sources, force: true)
        let phase = stoppedFor
            ?? (Task.isCancelled ? "Paused"
                : failed > 0 ? "Finished with \(failed) pictures not imported"
                : "Up to date")
        await report(phase: phase, running: false, error: lastError,
                     finished: stoppedFor == nil && !Task.isCancelled, done: pending.count, total: pending.count)
        await refreshCounts(remaining: Task.isCancelled || stoppedFor != nil ? nil : 0, failed: failed)
    }

    private var hasRoom: Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return true }
        return free >= minimumFreeBytes
    }

    /// Brings the record of handled paths and the listings up to date. Returns whether the bucket
    /// could be reached, which it needn't be if the drive is here. Off the actor because walking the
    /// drive takes a while, and pausing has to be able to get through.
    private nonisolated func prepareInventory(_ sources: Sources) async throws -> Bool {
        if let root = sources.drive, let driveID = sources.driveID {
            try StorageInventory.mergeHandledPaths(fromDrive: root, driveID: driveID)
            try StorageInventory.refreshDrive(root: root)
        }
        guard let bucket = sources.bucket else { return false }
        do {
            try await StorageInventory.mergeHandledPaths(fromS3: bucket.client, prefix: bucket.prefix, session: bucket.session)
            try await StorageInventory.refreshS3(client: bucket.client, prefix: bucket.prefix, session: bucket.session)
            return true
        } catch {
            if sources.drive == nil { throw error }
            return false
        }
    }

    private func candidates(sources: Sources, reachedS3: Bool) -> [ImportCandidate] {
        ImportPlanner.candidates(from: store.inventory(), handled: store.handledPaths(), importedTags: store.importedTags())
            .filter { (sources.drive != nil && $0.onDrive) || (reachedS3 && $0.onS3) }
    }

    /// Rebuilds the record of imported photos from the tags on the photos themselves, if the record
    /// is new or its asset IDs have stopped matching (as after restoring to another phone). Off the
    /// actor for the same reason as `prepareInventory`.
    private nonisolated func scanForImportsIfNeeded() async throws {
        if store.meta("imports-scanned") != nil {
            let known = Array(store.importedAssetIDs().prefix(100))
            let isStale = !known.isEmpty && PHAsset.fetchAssets(withLocalIdentifiers: known, options: nil).count == 0
            guard isStale else { return }
        }
        guard PhotoLibrary.hasFullAccess else { return }

        var found: [(assetID: String, tag: String)] = []
        var cancelled = false
        PhotoLibrary.fetchAllAssets().enumerateObjects { asset, _, stop in
            if Task.isCancelled {
                cancelled = true
                stop.pointee = true
                return
            }
            for resource in PHAssetResource.assetResources(for: asset) {
                if let tag = LibraryPath.tag(inFilename: resource.originalFilename) {
                    found.append((asset.localIdentifier, tag))
                    break
                }
            }
        }
        if cancelled { throw CancellationError() }
        store.replaceImportedAssets(found)

        let tags = Set(found.map(\.tag))
        store.markImported(paths: store.inventory().map(\.path).filter { tags.contains(LibraryPath.tag(for: $0)) })
        store.setMeta("imports-scanned", "1")
    }

    private func writeHandledPaths(_ sources: Sources, force: Bool) async {
        if let root = sources.drive, let driveID = sources.driveID {
            StorageInventory.writeHandledPaths(toDrive: root, driveID: driveID, force: force)
        }
        if let bucket = sources.bucket {
            await StorageInventory.writeHandledPaths(toS3: bucket.client, prefix: bucket.prefix, force: force, session: bucket.session)
        }
    }

    // MARK: - Making the copies

    private struct Prepared: Sendable {
        let path: String
        let output: ImageDownscaler.Result
    }

    private func prepare(_ batch: [ImportCandidate], sources: Sources, workspace: URL) async -> [(ImportCandidate, Result<Prepared, Error>)] {
        // Sendable copies for the child tasks.
        let drive = sources.drive
        let bucket = sources.bucket
        // Downloads wait on the network, so more can run at once than when reading from the drive.
        let width = drive == nil ? 4 : 2
        return await withTaskGroup(of: (ImportCandidate, Result<Prepared, Error>).self) { group in
            var results: [(ImportCandidate, Result<Prepared, Error>)] = []
            var iterator = batch.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    do {
                        return (item, .success(try await Self.prepareOne(item, drive: drive, bucket: bucket, workspace: workspace)))
                    } catch {
                        return (item, .failure(error))
                    }
                }
            }
            for _ in 0..<width { addNext() }
            while let result = await group.next() {
                results.append(result)
                if !Task.isCancelled { addNext() }
            }
            return results
        }
    }

    private static func prepareOne(_ item: ImportCandidate, drive: URL?, bucket: Bucket?, workspace: URL) async throws -> Prepared {
        try Task.checkCancellation()
        if let drive, item.onDrive {
            let output = try ImageDownscaler.process(source: drive.appending(path: item.path), into: workspace)
            return Prepared(path: item.path, output: output)
        }
        guard let bucket else { throw CocoaError(.fileNoSuchFile) }
        let key = [bucket.prefix, item.path].filter { !$0.isEmpty }.joined(separator: "/")
        let download = try await bucket.client.downloadObject(key: key, session: bucket.session)
        // ImageIO goes by contents, but the extension is used for a file passed through unchanged.
        let named = workspace.appendingPathComponent(UUID().uuidString).appendingPathExtension((item.path as NSString).pathExtension)
        defer {
            try? FileManager.default.removeItem(at: named)
            try? FileManager.default.removeItem(at: download)
        }
        try FileManager.default.moveItem(at: download, to: named)
        let output = try ImageDownscaler.process(source: named, into: workspace)
        return Prepared(path: item.path, output: output)
    }

    // MARK: - Adding to Photos

    private struct ImportOutcome {
        var imported = 0
        var failed = 0
        var lastError: String?
    }

    /// One bad file makes the system reject a whole batch, so a rejected batch is tried one at a
    /// time to find it.
    private func importToLibrary(_ items: [Prepared], albums: Albums) async -> ImportOutcome {
        guard !items.isEmpty else { return ImportOutcome() }
        do {
            store.recordImports(try await Self.create(items, albums: albums))
            return ImportOutcome(imported: items.count)
        } catch where items.count > 1 {
            var outcome = ImportOutcome()
            for item in items {
                let single = await importToLibrary([item], albums: albums)
                outcome.imported += single.imported
                outcome.failed += single.failed
                outcome.lastError = single.lastError ?? outcome.lastError
            }
            return outcome
        } catch {
            return ImportOutcome(failed: 1, lastError: "\(items[0].path): \(error.localizedDescription)")
        }
    }

    private static func create(_ items: [Prepared], albums: Albums) async throws -> [(assetID: String, path: String)] {
        final class Created: @unchecked Sendable {
            var rows: [(id: String, path: String)] = []
        }
        let created = Created()
        try await PHPhotoLibrary.shared().performChanges {
            let library = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albums.library], options: nil).firstObject
            let undated = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albums.undated], options: nil).firstObject
            let libraryRequest = library.flatMap { PHAssetCollectionChangeRequest(for: $0) }
            let undatedRequest = undated.flatMap { PHAssetCollectionChangeRequest(for: $0) }

            for item in items {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = LibraryPath.taggedFilename(for: item.path, fileExtension: item.output.fileExtension)
                options.uniformTypeIdentifier = item.output.uniformTypeIdentifier

                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: item.output.file, options: options)
                request.creationDate = item.output.date ?? ImportDate.fallback(for: item.path)
                if let latitude = item.output.latitude, let longitude = item.output.longitude {
                    request.location = CLLocation(latitude: latitude, longitude: longitude)
                }
                guard let placeholder = request.placeholderForCreatedAsset else { continue }
                created.rows.append((placeholder.localIdentifier, item.path))
                libraryRequest?.addAssets([placeholder] as NSArray)
                if LibraryPath.isUndated(item.path) { undatedRequest?.addAssets([placeholder] as NSArray) }
            }
        }
        return created.rows.map { (assetID: $0.id, path: $0.path) }
    }

    /// The albums imported photos go in, found by name.
    private struct Albums: Sendable {
        let library: String
        let undated: String

        static func findOrCreate() async throws -> Albums {
            Albums(library: try await album(titled: LibrarySyncEngine.albumTitle),
                   undated: try await album(titled: LibrarySyncEngine.undatedAlbumTitle))
        }

        private static func album(titled title: String) async throws -> String {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title == %@", title)
            if let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject {
                return album.localIdentifier
            }
            final class Created: @unchecked Sendable { var id = "" }
            let created = Created()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                created.id = request.placeholderForCreatedAssetCollection.localIdentifier
            }
            return created.id
        }
    }

    // MARK: - Status

    private func report(phase: String, running: Bool, error: String? = nil, finished: Bool = false, startingPass: Bool = false, done: Int? = nil, total: Int? = nil) async {
        if let done, let total { progressHandler?(phase, done, total) }
        await MainActor.run {
            let status = SyncStatus.shared
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
        }
    }

    private func refreshCounts(remaining: Int?, failed: Int) async {
        await MainActor.run {
            let status = SyncStatus.shared
            if let remaining { status.remaining = remaining }
            status.failed = failed
        }
    }
}

// MARK: - Sources

private struct Bucket: Sendable {
    let client: S3Client
    let prefix: String
    let session: URLSession
}

/// The drive, if it's connected, and the bucket, if it's set up.
private final class Sources: Sendable {
    let drive: URL?
    let driveID: String?
    let bucket: Bucket?

    private init(drive: URL?, driveID: String?, bucket: Bucket?) {
        self.drive = drive
        self.driveID = driveID
        self.bucket = bucket
    }

    static func open() -> Sources {
        var bucket: Bucket?
        if let settings = SettingsStore.snapshot(), let client = try? S3Client(config: settings.s3) {
            let config = URLSessionConfiguration.default
            config.allowsCellularAccess = settings.allowCellular
            bucket = Bucket(client: client, prefix: settings.prefix, session: URLSession(configuration: config))
        }
        let driveID = DriveDestination.id
        return Sources(drive: driveID == nil ? nil : DriveDestination.open(), driveID: driveID, bucket: bucket)
    }

    var isAvailable: Bool { drive != nil || bucket != nil }

    func close() {
        if let drive { DriveDestination.close(drive) }
        bucket?.session.finishTasksAndInvalidate()
    }
}
