import Foundation
import S3Kit
import SyncKit

/// Lists what's in storage, and keeps the record of handled paths there up to date.
///
/// The handled paths file is what lets a reinstalled app know what's been dealt with. It's merged
/// from each place the first time that place is seen, always before writing to it, so entries
/// already there are never lost.
enum StorageInventory {
    private static var store: BackupStore { .shared }
    /// How many changes to let build up before updating the copies in storage during a pass.
    private static let writeInterval = 500

    // MARK: - Drive

    /// Brings the record of handled paths and the listing of the drive up to date.
    static func prepareDrive(root: URL, driveID: String) throws {
        try mergeHandledPaths(fromDrive: root, driveID: driveID)
        try refreshDrive(root: root)
    }

    private static func refreshDrive(root: URL) throws {
        let entries = walk(root: root)
        // A walk cut short by the drive being unplugged would look like missing files.
        guard (try? root.checkResourceIsReachable()) == true else { throw CocoaError(.fileNoSuchFile) }
        store.replaceInventory(source: .drive, entries: entries)
    }

    private static func walk(root: URL) -> [InventoryEntry] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var entries: [InventoryEntry] = []
        for case let path as String in enumerator {
            guard enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
                  LibraryPath.isLibraryContent(path),
                  let size = enumerator.fileAttributes?[.size] as? NSNumber
            else { continue }
            entries.append(InventoryEntry(source: .drive, path: path, size: size.int64Value))
        }
        return entries
    }

    private static func mergeHandledPaths(fromDrive root: URL, driveID: String) throws {
        let key = "merged-drive-\(driveID)"
        guard store.meta(key) == nil else { return }
        let file = root.appending(path: HandledPathsFile.relativePath)
        if FileManager.default.fileExists(atPath: file.path) {
            store.mergeHandled(HandledPathsFile.decode(try Data(contentsOf: file)))
        }
        store.setMeta(key, "1")
    }

    /// Writes the record to the drive if it's out of date. `force` writes any change at all;
    /// otherwise this waits until enough have built up.
    static func writeHandledPaths(toDrive root: URL, driveID: String, force: Bool) {
        guard store.meta("merged-drive-\(driveID)") != nil else { return }
        let key = "written-drive-\(driveID)"
        guard isDue(key: key, force: force) else { return }
        let version = store.handledVersion
        let file = root.appending(path: HandledPathsFile.relativePath)
        let partial = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).partial")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HandledPathsFile.encode(store.handledEntries()).write(to: partial)
            guard rename(partial.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            store.setMeta(key, String(version))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            print("Couldn't write handled paths to the drive: \(error)")
        }
    }

    // MARK: - Bucket

    /// Brings the record of handled paths and the listing of the bucket up to date.
    static func prepareS3(client: S3Client, prefix: String, session: URLSession = .shared) async throws {
        try await mergeHandledPaths(fromS3: client, prefix: prefix, session: session)
        try await refreshS3(client: client, prefix: prefix, session: session)
    }

    private static func refreshS3(client: S3Client, prefix: String, session: URLSession) async throws {
        let root = prefix.isEmpty ? "" : "\(prefix)/"
        let objects = try await client.listObjects(prefix: root, session: session)
        let entries = objects.compactMap { object -> InventoryEntry? in
            let path = String(object.key.dropFirst(root.count))
            return LibraryPath.isLibraryContent(path) ? InventoryEntry(source: .s3, path: path, size: object.size) : nil
        }
        store.replaceInventory(source: .s3, entries: entries)
        store.setMeta(listedKey(client: client, prefix: prefix), "1")
    }

    /// Whether this bucket has ever been listed, which name collisions are checked against.
    static func hasListedS3(client: S3Client, prefix: String) -> Bool {
        store.meta(listedKey(client: client, prefix: prefix)) != nil
    }

    private static func mergeHandledPaths(fromS3 client: S3Client, prefix: String, session: URLSession) async throws {
        let key = "merged-s3-\(identity(client: client, prefix: prefix))"
        guard store.meta(key) == nil else { return }
        do {
            let data = try await client.getObject(key: handledKey(prefix: prefix), session: session)
            store.mergeHandled(HandledPathsFile.decode(data))
        } catch let error as S3Error where error.status == 404 {
            // Nothing there yet.
        }
        store.setMeta(key, "1")
    }

    static func writeHandledPaths(toS3 client: S3Client, prefix: String, force: Bool, session: URLSession = .shared) async {
        let id = identity(client: client, prefix: prefix)
        guard store.meta("merged-s3-\(id)") != nil else { return }
        let key = "written-s3-\(id)"
        guard isDue(key: key, force: force) else { return }
        let version = store.handledVersion
        do {
            try await client.putObject(key: handledKey(prefix: prefix), data: HandledPathsFile.encode(store.handledEntries()),
                                       contentType: "application/x-ndjson", session: session)
            store.setMeta(key, String(version))
        } catch {
            print("Couldn't write handled paths to the bucket: \(error)")
        }
    }

    // MARK: - Helpers

    private static func isDue(key: String, force: Bool) -> Bool {
        let written = Int(store.meta(key) ?? "") ?? -1
        let current = store.handledVersion
        return force ? written != current : current - written >= writeInterval
    }

    private static func handledKey(prefix: String) -> String {
        LibraryPath.key(prefix: prefix, path: HandledPathsFile.relativePath)
    }

    private static func identity(client: S3Client, prefix: String) -> String {
        "\(client.config.bucket)/\(prefix)"
    }

    private static func listedKey(client: S3Client, prefix: String) -> String {
        "listed-s3-\(identity(client: client, prefix: prefix))"
    }
}
