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

    /// Every photo and video in the library, newest first. Only `LibrarySnapshot` and the scan for
    /// imports list it.
    static func fetchAllAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: options)
    }

    /// Full access, which syncing to the phone needs: with limited access imported photos can't
    /// all be seen, so they'd be imported again.
    static var hasFullAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// `id`'s asset as it is now. A pass reads the modification date it records from this, before
    /// exporting, not from the library snapshot, which may be older than an edit made since.
    static func freshAsset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
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

    /// The size of `resource`'s file without reading it, from `PHAssetResource`'s undocumented
    /// `fileSize` property. Nil if this system doesn't have it.
    static func fileSize(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: NSSelectorFromString("fileSize")),
              let size = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value, size > 0
        else { return nil }
        return size
    }

    /// Writes the original bytes of `resource` to `url`, downloading from iCloud if necessary.
    static func export(_ resource: PHAssetResource, to url: URL) async throws {
        Log.export.info("Exporting \(resource.originalFilename, privacy: .public)")
        let signpost = Log.signposter.beginInterval("export", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("export", signpost) }
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
        Log.export.info("Streaming \(resource.originalFilename, privacy: .public)")
        let signpost = Log.signposter.beginInterval("export", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("export", signpost) }
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
