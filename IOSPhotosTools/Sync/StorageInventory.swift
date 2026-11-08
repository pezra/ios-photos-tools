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

    enum Failure: Error, LocalizedError {
        case couldNotSave

        var errorDescription: String? {
            "Couldn't save the record of what's in storage. This phone may be out of space."
        }
    }

    // MARK: - Drive

    /// A listing this recent is used as it is, so a sync straight after a drive backup doesn't
    /// read the whole drive again.
    private static let driveListingFreshFor: TimeInterval = 10 * 60

    /// Brings the record of handled paths and the listing of the drive up to date. The listing is
    /// saved as it goes, so one cut short carries on next time. `progress` is told how many files
    /// have been found so far.
    static func prepareDrive(root: URL, driveID: String, progress: ((Int) async -> Void)? = nil) async throws {
        try mergeHandledPaths(fromDrive: root, driveID: driveID)
        try await DriveListing(store: store, root: root, key: "drive-listing-\(driveID)")
            .run(freshFor: driveListingFreshFor, progress: progress)
    }

    private static func mergeHandledPaths(fromDrive root: URL, driveID: String) throws {
        let key = "merged-drive-\(driveID)"
        guard store.meta(key) == nil else { return }
        let file = root.appending(path: HandledPathsFile.relativePath)
        if FileManager.default.fileExists(atPath: file.path) {
            guard store.mergeHandled(HandledPathsFile.decode(try Data(contentsOf: file)), from: .drive) else { throw Failure.couldNotSave }
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

    /// Brings the record of handled paths and the listing of the bucket up to date. `progress` is
    /// told how many objects have been listed so far.
    static func prepareS3(client: S3Client, prefix: String, session: URLSession,
                          progress: ((Int) async -> Void)? = nil) async throws {
        // What's been checked in one bucket says nothing about another.
        let current = identity(client: client, prefix: prefix)
        let previous = store.meta("current-bucket")
        if previous != current {
            // Identities used to leave out the service, so one of those is taken to be this bucket.
            let isOlderForm = previous == "\(client.config.bucket)/\(prefix)"
            if previous != nil && !isOlderForm { store.forgetBucketContents() }
            store.setMeta("current-bucket", current)
        }
        try await mergeHandledPaths(fromS3: client, prefix: prefix, session: session)
        try await refreshS3(client: client, prefix: prefix, session: session, progress: progress)
    }

    private static func refreshS3(client: S3Client, prefix: String, session: URLSession,
                                  progress: ((Int) async -> Void)?) async throws {
        let root = prefix.isEmpty ? "" : "\(prefix)/"
        let objects = try await client.listObjects(prefix: root, session: session, progress: progress)
        let entries = objects.compactMap { object -> InventoryEntry? in
            let path = String(object.key.dropFirst(root.count))
            return LibraryPath.isLibraryContent(path) ? InventoryEntry(source: .s3, path: path, size: object.size) : nil
        }
        guard store.replaceInventory(source: .s3, entries: entries) else { throw Failure.couldNotSave }
        store.setMeta(listedKey(client: client, prefix: prefix), "1")
    }

    /// Whether uploads to this bucket can ask to be refused if a name is taken, the last guard
    /// against overwriting a different picture. Asks the bucket now and then, since services can
    /// start supporting it. If it can't be asked, assumes the last answer, or that it can.
    static func supportsConditionalWrites(client: S3Client, prefix: String, session: URLSession) async -> Bool {
        let key = conditionalWritesKey(client: client, prefix: prefix)
        let known = store.meta(key)?.split(separator: " ")
        let isCurrent = known.flatMap { $0.last }.flatMap { Double($0) }
            .map { Date().timeIntervalSince1970 - $0 < conditionalWritesCheckInterval } ?? false
        if let answer = known?.first, isCurrent, store.meta(recheckConditionalWritesKey) != "1" { return answer == "1" }
        do {
            return try await checkConditionalWrites(client: client, prefix: prefix, session: session)
        } catch {
            print("Couldn't check for conditional writes: \(error)")
            return known?.first.map { $0 == "1" } ?? true
        }
    }

    /// Asks the bucket, and remembers the answer.
    static func checkConditionalWrites(client: S3Client, prefix: String, session: URLSession) async throws -> Bool {
        let probe = LibraryPath.key(prefix: prefix, path: ".photos-tools/conditional-write-check")
        let supported = try await client.supportsConditionalWrites(key: probe, session: session)
        store.setMeta(conditionalWritesKey(client: client, prefix: prefix), "\(supported ? 1 : 0) \(Date().timeIntervalSince1970)")
        store.setMeta(recheckConditionalWritesKey, "0")
        return supported
    }

    /// Whether this bucket is known not to support them, which is worth telling the user about.
    static func lacksConditionalWrites(client: S3Client, prefix: String) -> Bool {
        store.meta(conditionalWritesKey(client: client, prefix: prefix))?.hasPrefix("0") == true
    }

    /// For an upload turned away for asking, which means the last answer is out of date.
    static func recheckConditionalWrites() {
        store.setMeta(recheckConditionalWritesKey, "1")
    }

    private static let conditionalWritesCheckInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let recheckConditionalWritesKey = "recheck-conditional-writes"

    private static func conditionalWritesKey(client: S3Client, prefix: String) -> String {
        "conditional-writes-\(identity(client: client, prefix: prefix))"
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
            guard store.mergeHandled(HandledPathsFile.decode(data), from: .s3) else { throw Failure.couldNotSave }
        } catch let error as S3Error where error.status == 404 {
            // Nothing there yet.
        }
        store.setMeta(key, "1")
    }

    static func writeHandledPaths(toS3 client: S3Client, prefix: String, force: Bool, session: URLSession) async {
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

    /// The service is part of it, since a bucket of the same name elsewhere is a different one.
    private static func identity(client: S3Client, prefix: String) -> String {
        let endpoint = client.config.endpoint
        let service = (endpoint.host ?? "").lowercased() + (endpoint.port.map { ":\($0)" } ?? "")
        return "\(service)/\(client.config.bucket)/\(prefix)"
    }

    private static func listedKey(client: S3Client, prefix: String) -> String {
        "listed-s3-\(identity(client: client, prefix: prefix))"
    }
}
