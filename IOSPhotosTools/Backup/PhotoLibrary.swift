import Photos
import SyncKit
import UniformTypeIdentifiers

enum PhotoLibrary {
    /// Original-quality files to back up. Adjustment data/base files are skipped, but rendered
    /// edits (`fullSize*`) are kept alongside the originals.
    static let backedUpTypes: Set<PHAssetResourceType> = [
        .photo, .video, .audio, .alternatePhoto, .pairedVideo,
        .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo,
    ]

    /// Rendered edits. These keep the same file name each time the photo is re-edited.
    static let editedTypes: Set<PHAssetResourceType> = [.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo]

    static var isAuthorized: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    /// Every photo and video in the library, newest first.
    static func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: options)
    }

    /// Calls `body` with each of `assets` except the low-res copies imported from storage.
    static func enumerateOwnAssets(_ assets: PHFetchResult<PHAsset>, _ body: @escaping (PHAsset) -> Void) {
        let imported = BackupStore.shared.importedAssetIDs()
        assets.enumerateObjects { asset, _, _ in
            if !imported.contains(asset.localIdentifier) { body(asset) }
        }
    }

    /// Full access, which syncing to the phone needs: with limited access imported photos can't
    /// all be seen, so they'd be imported again.
    static var hasFullAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// Assets that need backing up, given `completed` (asset ID → the asset's modification date
    /// when it was backed up), and the IDs of every asset in the library that gets backed up.
    /// Low-res copies imported from storage are left out of both.
    ///
    /// New assets are included, plus completed ones modified since (e.g. edited) so new edits are
    /// backed up, and ones whose date is unknown.
    static func pendingAssets(completed: [String: Double?]) -> (pending: [PHAsset], allIDs: [String]) {
        var pending: [PHAsset] = []
        var ids: [String] = []
        enumerateOwnAssets(fetchAllAssets()) { asset in
            ids.append(asset.localIdentifier)
            guard let backedUpAt = completed[asset.localIdentifier] else { return pending.append(asset) }
            if let backedUpAt, let modified = asset.modificationDate?.timeIntervalSince1970, modified <= backedUpAt { return }
            pending.append(asset)
        }
        return (pending, ids)
    }

    /// The tag on a photo imported from storage, if these are the files of one.
    static func importTag(in resources: [PHAssetResource]) -> String? {
        resources.lazy.compactMap { LibraryPath.tag(inFilename: $0.originalFilename) }.first
    }

    /// The files of `asset` to back up. A photo imported from storage has none: this goes by the
    /// tag on the photo itself, so a low-res copy can't overwrite or join the backup even if the
    /// database has lost track of it.
    static func backupCandidates(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)
        guard importTag(in: resources) == nil else { return [] }
        return resources.filter { backedUpTypes.contains($0.type) }
    }

    /// The year folder an asset's files go in.
    static func backupFolder(for asset: PHAsset) -> String {
        BackupNaming.folder(year: asset.creationDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) })
    }

    static func contentType(of resource: PHAssetResource) -> String {
        UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Writes the original bytes of `resource` to `url`, downloading from iCloud if necessary.
    static func export(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Like `export`, but writes the bytes from this process, so files on a security-scoped
    /// location such as a USB drive don't depend on the Photos service being able to reach it.
    static func stream(_ resource: PHAssetResource, to url: URL) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        /// Tracks the request so it can be cancelled from the write handler or when the task is
        /// cancelled, which may happen before `requestData` has returned its ID.
        final class Request: @unchecked Sendable {
            private let lock = NSLock()
            private var id: PHAssetResourceDataRequestID?
            private var isCancelled = false
            /// Only touched by the data and completion handlers, which run one at a time.
            var writeError: Error?

            func started(_ id: PHAssetResourceDataRequestID) {
                let cancelNow = lock.withLock {
                    self.id = id
                    return isCancelled
                }
                if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }
            }

            func cancel() {
                let id = lock.withLock {
                    isCancelled = true
                    return self.id
                }
                if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        }
        let request = Request()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    guard request.writeError == nil else { return }
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        request.writeError = error
                        request.cancel()
                    }
                } completionHandler: { error in
                    if let error = request.writeError ?? error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                request.started(id)
            }
        } onCancel: {
            request.cancel()
        }
        try handle.synchronize()
    }
}
