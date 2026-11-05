import Foundation
import Photos
import S3Kit
import SyncKit

/// Gives an asset's files their paths in the library, shared by the bucket and the drive.
enum BackupPaths {
    enum Failure: Error, LocalizedError {
        case stillContended
        case cannotCompare(String)
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .stillContended: "Another photo keeps taking this photo's file name. It will be tried again."
            case let .cannotCompare(path): "\(path) already exists, but it can't be read to compare with this photo. It will be tried again."
            case let .nameTaken(path): "A different picture is already at \(path). This photo will get a new name on the next pass."
            }
        }
    }

    /// The resources of `asset` to back up, with their rows. Paths are chosen the first time and
    /// kept, so both destinations always agree.
    static func assign(_ asset: PHAsset, prefix: String) async throws -> [(PHAssetResource, ResourceRow)] {
        let store = BackupStore.shared
        let resources = PhotoLibrary.backupCandidates(for: asset)
        guard !resources.isEmpty else { return [] }
        let files = resources.map { BackupFile(originalFilename: $0.originalFilename, isEdit: PhotoLibrary.editedTypes.contains($0.type)) }
        let ids = resources.map { "\(asset.localIdentifier)#\($0.type.rawValue)#\($0.originalFilename)" }
        let folder = PhotoLibrary.backupFolder(for: asset)

        func rows(_ paths: [String]) -> [ResourceRow] {
            zip(ids, paths).map { id, path in
                ResourceRow(id: id, assetID: asset.localIdentifier, path: path, s3Key: LibraryPath.key(prefix: prefix, path: path))
            }
        }

        // Up to a few tries, since another pass could take a name while this one compares files.
        for _ in 0..<5 {
            var existing = store.paths(forAsset: asset.localIdentifier)
            // Every file already holds its path, so there's nothing to claim.
            if ids.allSatisfy({ existing[$0] != nil }) {
                return Array(zip(resources, rows(ids.compactMap { existing[$0] })))
            }
            var paths: [String]
            if !existing.isEmpty, let extended = BackupNaming.extending(ids.map { existing[$0] }, files: files, folder: folder) {
                // A photo edited since its backup: the edit joins the files already there.
                paths = extended
            } else {
                if !existing.isEmpty {
                    store.retirePaths(forAsset: asset.localIdentifier)
                    // They're no longer this photo's, so its edits need their paths checked below.
                    existing = [:]
                }
                paths = try await resolve(resources: resources, files: files, folder: folder, ownIDs: Set(ids))
            }
            for index in paths.indices where files[index].isEdit && existing[ids[index]] == nil {
                paths[index] = BackupNaming.editPath(paths[index]) { isTaken($0, ownIDs: Set(ids)) }
            }
            let result = rows(paths)
            if store.claim(result) { return Array(zip(resources, result)) }
        }
        throw Failure.stillContended
    }

    /// Whether something other than this photo's own files is at `path`.
    private static func isTaken(_ path: String, ownIDs: Set<String>) -> Bool {
        let store = BackupStore.shared
        switch store.pathHolder(path) {
        case .free: return !store.inventoryEntries(for: path).isEmpty
        case .released: return true
        case let .resource(id): return !ownIDs.contains(id)
        }
    }

    private static func resolve(resources: [PHAssetResource], files: [BackupFile], folder: String, ownIDs: Set<String>) async throws -> [String] {
        let store = BackupStore.shared
        var exports: [Int: Export] = [:]
        defer { exports.values.forEach { try? FileManager.default.removeItem(at: $0.file) } }

        return try await BackupNaming.resolve(
            files: files,
            folder: folder,
            isOccupied: { isTaken($0, ownIDs: ownIDs) },
            isIdentical: { index, path in
                if case let .resource(holder) = store.pathHolder(path), !ownIDs.contains(holder) {
                    // Another photo's file, unless that photo is gone: after restoring to another
                    // phone the IDs are all different, and this may be the same photo.
                    let holderAsset = ResourceRow.assetID(ofResource: holder)
                    guard PHAsset.fetchAssets(withLocalIdentifiers: [holderAsset], options: nil).count == 0 else { return false }
                    store.releasePath(path)
                }
                let entries = store.inventoryEntries(for: path)
                guard !entries.isEmpty else { return false }

                let export: Export
                if let cached = exports[index] {
                    export = cached
                } else {
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try await PhotoLibrary.export(resources[index], to: file)
                    export = Export(file: file, size: file.fileSize ?? -1, sha256: try Staging.sha256(of: file))
                    exports[index] = export
                }
                guard entries.allSatisfy({ $0.size == export.size }) else { return false }
                return try await sha256(ofExisting: entries, path: path) == export.sha256
            }
        )
    }

    private struct Export {
        let file: URL
        let size: Int64
        let sha256: String
    }

    /// Reads whichever copy can be reached.
    static func sha256(ofExisting entries: [InventoryEntry], path: String) async throws -> String {
        if let entry = entries.first(where: { $0.source == .drive }), let root = DriveDestination.open() {
            defer { DriveDestination.close(root) }
            if let hash = try? Staging.sha256(of: root.appending(path: entry.path)) { return hash }
        }
        if let entry = entries.first(where: { $0.source == .s3 }), let settings = SettingsStore.snapshot(),
           let client = try? S3Client(config: settings.s3) {
            let session = settings.bucketSession()
            defer { session.finishTasksAndInvalidate() }
            let file = try await client.downloadObject(key: LibraryPath.key(prefix: settings.prefix, path: entry.path), session: session)
            defer { try? FileManager.default.removeItem(at: file) }
            return try Staging.sha256(of: file)
        }
        throw Failure.cannotCompare(path)
    }
}
