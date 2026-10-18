import Photos
import UniformTypeIdentifiers

enum PhotoLibrary {
    /// Original-quality files to back up. Adjustment data/base files are skipped, but rendered
    /// edits (`fullSize*`) are kept alongside the originals.
    static let backedUpTypes: Set<PHAssetResourceType> = [
        .photo, .video, .audio, .alternatePhoto, .pairedVideo,
        .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo,
    ]

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
}
