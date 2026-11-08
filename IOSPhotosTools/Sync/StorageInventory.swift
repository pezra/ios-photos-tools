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

    // MARK: - Drive

    /// A listing this recent is used as it is, so a sync straight after a drive backup doesn't
    /// read the whole drive again.
    private static let driveListingFreshFor: TimeInterval = 10 * 60

    /// Brings the record of handled paths and the listing of the drive up to date. The listing is
    /// saved as it goes, so one cut short carries on next time. `progress` is told how many files
    /// have been found so far.
    static func prepareDrive(root: URL, driveID: String, progress: ((Int) async -> Void)? = nil) async throws {
        try useDrive(driveID, assumingPrevious: nil)
        try mergeHandledPaths(fromDrive: root, driveID: driveID)
        let found = try await Log.interval("drive listing") {
            try await DriveListing(store: store, root: root, key: Destination.drive(driveID).listingKey)
                .run(freshFor: driveListingFreshFor, progress: progress)
        }
        if let found {
            Log.listing.info("Drive listed: \(found) files")
        } else {
            Log.listing.info("Drive listing reused: finished within \(Int(driveListingFreshFor)) s")
        }
    }

    /// The drive folder changed, if it isn't the one last used: what was kept about the old one goes.
    /// Choosing a folder does this straight away; this catches up a database that wasn't told.
    static func useDrive(_ driveID: String?, assumingPrevious: String?) throws {
        if try store.useDrive(driveID, assumingPrevious: assumingPrevious) {
            Log.pass.info("Drive folder changed: what was kept about the old one is gone")
        }
    }

    private static func mergeHandledPaths(fromDrive root: URL, driveID: String) throws {
        let key = Destination.drive(driveID).mergedKey
        guard store.meta(key) == nil else { return }
        let file = root.appending(path: HandledPathsFile.relativePath)
        if FileManager.default.fileExists(atPath: file.path) {
            guard store.mergeHandled(HandledPathsFile.decode(try Data(contentsOf: file)), from: .drive) else { throw BackupStore.Failure.couldNotSave }
        }
        store.setMeta(key, "1")
        Log.handledPaths.info("Merged handled paths from the drive")
    }

    /// Writes the record to the drive if it's out of date. `force` writes any change at all;
    /// otherwise this waits until 5 minutes have passed since the last write.
    static func writeHandledPaths(toDrive root: URL, driveID: String, force: Bool) async {
        guard store.meta(Destination.drive(driveID).mergedKey) != nil else { return }
        let file = root.appending(path: HandledPathsFile.relativePath)
        let partial = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).partial")
        do {
            let version = try await writer(Destination.drive(driveID).writtenKey).write(force: force) { data in
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: partial)
                    guard rename(partial.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
            }
            if let version { Log.handledPaths.info("Wrote handled paths to the drive at version \(version)") }
        } catch {
            Log.handledPaths.error("Couldn't write handled paths to the drive: \(error)")
        }
    }

    // MARK: - Bucket

    /// A listing of the bucket this recent is used as it is, since one background run backs up,
    /// copies to the drive and syncs, and each would otherwise list the whole bucket. This app's
    /// own uploads are recorded as they finish, so only files put there by something else are
    /// missed for a while, and a bucket that refuses uploads to taken names won't let an upload
    /// land on one. One that can't refuse them has only the listing, so it's always listed again.
    private static let s3ListingFreshFor: TimeInterval = 10 * 60

    /// Brings the record of handled paths and the listing of the bucket up to date. `progress` is
    /// told how many objects have been listed so far.
    static func prepareS3(client: S3Client, prefix: String, session: URLSession,
                          progress: ((Int) async -> Void)? = nil) async throws {
        try noticeBucket(client: client, prefix: prefix)
        let listedAt = store.meta(listedKey(client: client, prefix: prefix)).flatMap(Double.init) ?? 0
        let isFresh = hasListedS3(client: client, prefix: prefix) && !lacksConditionalWrites(client: client, prefix: prefix)
            && Date().timeIntervalSince1970 - listedAt < s3ListingFreshFor
        try await mergeHandledPaths(fromS3: client, prefix: prefix, session: session)
        if isFresh {
            Log.listing.info("Bucket listing reused: listed within \(Int(s3ListingFreshFor)) s")
        } else {
            try await Log.interval("bucket listing") {
                try await refreshS3(client: client, prefix: prefix, session: session, progress: progress)
            }
        }
    }

    /// What's been backed up to one bucket says nothing about another, so switching to a different
    /// one forgets the backup history and backs everything up to it.
    static func noticeBucket(client: S3Client, prefix: String) throws {
        let current = identity(client: client, prefix: prefix)
        // Identities used to leave out the service, so one of those is taken to be this bucket.
        let olderForm = "\(client.config.bucket)/\(prefix)"
        if try store.useBucket(current, olderForm: olderForm, listedKey: listedKey(client: client, prefix: prefix)) {
            Log.pass.info("Bucket changed to \(current, privacy: .public): backup history forgotten")
        }
    }

    private static func refreshS3(client: S3Client, prefix: String, session: URLSession,
                                  progress: ((Int) async -> Void)?) async throws {
        let objects = try await client.listObjects(prefix: LibraryPath.key(prefix: prefix, path: ""), session: session, progress: progress)
        let entries = objects.compactMap { object -> InventoryEntry? in
            guard let path = LibraryPath.path(fromKey: object.key, prefix: prefix), LibraryPath.isLibraryContent(path) else { return nil }
            return InventoryEntry(source: .s3, path: path, size: object.size)
        }
        guard store.replaceInventory(source: .s3, entries: entries) else { throw BackupStore.Failure.couldNotSave }
        store.setMeta(listedKey(client: client, prefix: prefix), String(Date().timeIntervalSince1970))
        Log.listing.info("Bucket listed: \(objects.count) objects, \(entries.count) library files")
    }

    /// Whether uploads to this bucket can ask to be refused if a name is taken, the last guard
    /// against overwriting a different picture. Asks the bucket now and then, since services can
    /// start supporting it. If it can't be asked, assumes the last answer, or that it can.
    static func supportsConditionalWrites(client: S3Client, prefix: String, session: URLSession) async -> Bool {
        let key = conditionalWritesKey(client: client, prefix: prefix)
        let known = store.meta(key)?.split(separator: " ")
        let isCurrent = known.flatMap { $0.last }.flatMap { Double($0) }
            .map { Date().timeIntervalSince1970 - $0 < conditionalWritesCheckInterval } ?? false
        if let answer = known?.first, isCurrent, !store.needsConditionalWritesRecheck(bucket: identity(client: client, prefix: prefix)) { return answer == "1" }
        do {
            return try await checkConditionalWrites(client: client, prefix: prefix, session: session)
        } catch {
            Log.upload.error("Couldn't check for conditional writes: \(error)")
            return known?.first.map { $0 == "1" } ?? true
        }
    }

    /// Asks the bucket, and remembers the answer.
    static func checkConditionalWrites(client: S3Client, prefix: String, session: URLSession) async throws -> Bool {
        let probe = LibraryPath.key(prefix: prefix, path: ".photos-tools/conditional-write-check")
        let supported = try await client.supportsConditionalWrites(key: probe, session: session)
        store.setMeta(conditionalWritesKey(client: client, prefix: prefix), "\(supported ? 1 : 0) \(Date().timeIntervalSince1970)")
        store.conditionalWritesRechecked(bucket: identity(client: client, prefix: prefix))
        Log.upload.info("Conditional writes checked: \(supported ? "supported" : "not supported", privacy: .public)")
        return supported
    }

    /// Whether this bucket is known not to support them, which is worth telling the user about.
    static func lacksConditionalWrites(client: S3Client, prefix: String) -> Bool {
        store.meta(conditionalWritesKey(client: client, prefix: prefix))?.hasPrefix("0") == true
    }

    /// For an upload the bucket refused because something is at its key. What's there is added to
    /// the listing, so the next pass compares it with the photo and adopts this phone's own earlier
    /// upload rather than giving the photo a new name. Then the file is put back to be sent.
    static func uploadRefused(_ resourceID: String) async {
        guard let sent = store.uploadDestination(ofResource: resourceID),
              let settings = SettingsStore.snapshot(), let client = try? S3Client(config: settings.s3),
              sent.bucket == identity(client: client, prefix: settings.prefix)
        else {
            // Sent to a bucket that isn't the one chosen now, whose listing isn't kept.
            store.retirePaths(forResource: resourceID)
            return
        }
        let session = settings.bucketSession()
        defer { session.finishTasksAndInvalidate() }
        do {
            guard let size = try await client.headObject(key: LibraryPath.key(prefix: settings.prefix, path: sent.path), session: session) else {
                Log.upload.info("Upload refused, but nothing is at \(sent.path, privacy: .public) now: it's sent again")
                store.resetToPending(resourceID)
                return
            }
            if store.addInventory(source: .s3, entries: [InventoryEntry(source: .s3, path: sent.path, size: size)]) {
                Log.upload.info("Upload refused: \(sent.path, privacy: .public) is taken (\(size) bytes), added to the listing")
            }
            store.retirePaths(forResource: resourceID)
        } catch is URLError {
            // Couldn't reach the bucket, so nothing is known about what's there. The same name is
            // tried again, and refused again if it's still taken.
            Log.upload.error("Couldn't look at \(sent.path, privacy: .public) after its upload was refused: it's sent again")
            store.resetToPending(resourceID)
        } catch {
            Log.upload.error("Couldn't look at \(sent.path, privacy: .public) after its upload was refused: \(error)")
            store.retirePaths(forResource: resourceID)
        }
    }

    /// For an upload turned away for asking, which means the last answer for the bucket it was
    /// sent to is out of date. Said once for each bucket, not for every upload turned away.
    static func recheckConditionalWrites(afterUploadOf resourceID: String) {
        if let bucket = store.requestConditionalWritesRecheck(afterUploadOf: resourceID) {
            Log.upload.info("Upload refused for asking: \(bucket, privacy: .public) will be asked about conditional writes again")
        }
    }

    private static let conditionalWritesCheckInterval: TimeInterval = 7 * 24 * 60 * 60

    private static func conditionalWritesKey(client: S3Client, prefix: String) -> String {
        destination(client: client, prefix: prefix).conditionalWritesKey
    }

    /// Whether the listing kept, which name collisions are checked against, is this bucket's. It's
    /// only kept for the last bucket listed, so one listed before a switch has to be listed again.
    static func hasListedS3(client: S3Client, prefix: String) -> Bool {
        store.meta("current-bucket") == identity(client: client, prefix: prefix)
            && store.meta(listedKey(client: client, prefix: prefix)) != nil
    }

    private static func mergeHandledPaths(fromS3 client: S3Client, prefix: String, session: URLSession) async throws {
        let key = destination(client: client, prefix: prefix).mergedKey
        guard store.meta(key) == nil else { return }
        do {
            let data = try await client.getObject(key: handledKey(prefix: prefix), session: session)
            guard store.mergeHandled(HandledPathsFile.decode(data), from: .s3) else { throw BackupStore.Failure.couldNotSave }
        } catch let error as S3Error where error.status == 404 {
            // Nothing there yet.
        }
        store.setMeta(key, "1")
        Log.handledPaths.info("Merged handled paths from the bucket")
    }

    static func writeHandledPaths(toS3 client: S3Client, prefix: String, force: Bool, session: URLSession) async {
        guard store.meta(destination(client: client, prefix: prefix).mergedKey) != nil else { return }
        let key = handledKey(prefix: prefix)
        do {
            let version = try await writer(destination(client: client, prefix: prefix).writtenKey).write(force: force) { data in
                try await client.putObject(key: key, data: data, contentType: "application/x-ndjson", session: session)
            }
            if let version { Log.handledPaths.info("Wrote handled paths to the bucket at version \(version)") }
        } catch {
            Log.handledPaths.error("Couldn't write handled paths to the bucket: \(error)")
        }
    }

    // MARK: - Helpers

    /// Each place has one writer, whichever pass is writing to it. `key` records what was written.
    private static func writer(_ key: String) -> HandledPathsWriter {
        HandledPathsWriter.shared(store: store, key: key)
    }

    private static func handledKey(prefix: String) -> String {
        LibraryPath.key(prefix: prefix, path: HandledPathsFile.relativePath)
    }

    /// The service is part of it, since a bucket of the same name elsewhere is a different one.
    static func identity(client: S3Client, prefix: String) -> String {
        let endpoint = client.config.endpoint
        let service = (endpoint.host ?? "").lowercased() + (endpoint.port.map { ":\($0)" } ?? "")
        return "\(service)/\(client.config.bucket)/\(prefix)"
    }

    private static func destination(client: S3Client, prefix: String) -> Destination {
        .bucket(identity(client: client, prefix: prefix))
    }

    private static func listedKey(client: S3Client, prefix: String) -> String {
        destination(client: client, prefix: prefix).listingKey
    }
}
