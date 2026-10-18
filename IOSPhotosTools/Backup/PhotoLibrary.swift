import Photos
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

    /// Assets that need backing up, given `completed` (asset ID → the asset's modification date
    /// when it was backed up), and the IDs of every asset in the library.
    ///
    /// New assets are included, plus completed ones modified since (e.g. edited) so new edits are
    /// backed up, and ones whose date is unknown.
    static func pendingAssets(completed: [String: Double?]) -> (pending: [PHAsset], allIDs: [String]) {
        var pending: [PHAsset] = []
        var ids: [String] = []
        fetchAllAssets().enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
            guard let backedUpAt = completed[asset.localIdentifier] else { return pending.append(asset) }
            if let backedUpAt, let modified = asset.modificationDate?.timeIntervalSince1970, modified <= backedUpAt { return }
            pending.append(asset)
        }
        return (pending, ids)
    }

    /// The resources of `asset` to back up, paired with their stable ID and object key.
    static func backupResources(for asset: PHAsset, prefix: String) -> [(PHAssetResource, ResourceRow)] {
        // localIdentifier looks like "UUID/L0/001"; the UUID alone is unique and path-safe.
        let assetUUID = asset.localIdentifier.split(separator: "/").first.map(String.init) ?? asset.localIdentifier
        let folder: String
        if let date = asset.creationDate {
            let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
            folder = String(format: "%04d/%02d", parts.year ?? 0, parts.month ?? 0)
        } else {
            folder = "undated"
        }

        var usedNames = Set<String>()
        return PHAssetResource.assetResources(for: asset)
            .filter { backedUpTypes.contains($0.type) }
            .map { resource in
                var name = resource.originalFilename.replacingOccurrences(of: "/", with: "_")
                if name.isEmpty { name = "resource" }
                if usedNames.contains(name) { name = "\(resource.type.rawValue)-\(name)" }
                usedNames.insert(name)

                let key = [prefix, folder, assetUUID, name].filter { !$0.isEmpty }.joined(separator: "/")
                let row = ResourceRow(id: "\(asset.localIdentifier)#\(resource.type.rawValue)#\(name)",
                                      assetID: asset.localIdentifier,
                                      s3Key: key)
                return (resource, row)
            }
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
