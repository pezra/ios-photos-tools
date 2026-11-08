import Foundation
import SQLite3

public enum ResourceState: Int, Sendable {
    case pending = 0
    case uploading = 1
    case done = 2
    case failed = 3
}

/// One file (photo, video, Live Photo movie, edited render, …) belonging to a library asset.
public struct ResourceRow: Sendable {
    public let id: String
    public let assetID: String
    /// Where the file goes in the library, e.g. `2026/IMG_1234.HEIC`.
    public let path: String
    /// `path` under the bucket's folder.
    public let s3Key: String

    public init(id: String, assetID: String, path: String, s3Key: String) {
        self.id = id
        self.assetID = assetID
        self.path = path
        self.s3Key = s3Key
    }

    /// Resource IDs start with the asset's identifier.
    public static func assetID(ofResource id: String) -> String {
        id.split(separator: "#").first.map(String.init) ?? id
    }
}

/// Who a library path belongs to.
public enum PathHolder: Sendable, Equatable {
    case free
    /// Handled, but not by a resource: an imported or retired path.
    case released
    case resource(String)
}

/// Persistent record of what has been backed up, in a small SQLite database.
///
/// An asset is complete once every one of its resources has uploaded. Safe to call from any thread.
public final class BackupStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private var libraryLoaded = false

    /// `onLayoutChange` runs if opening this database moves it to a new layout, which everything
    /// is backed up again for.
    public init(path: String, onLayoutChange: () -> Void) {
        db = SQLiteDatabase(path: path)
        db.executeScript("""
            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                completed_at REAL NOT NULL,
                modified_at REAL
            );
            CREATE TABLE IF NOT EXISTS resources (
                id TEXT PRIMARY KEY,
                asset_id TEXT NOT NULL,
                s3_key TEXT NOT NULL,
                state INTEGER NOT NULL,
                staged_name TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                updated_at REAL NOT NULL,
                sha256 TEXT,
                asset_modified_at REAL,
                superseded INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS resources_asset ON resources(asset_id);
            CREATE INDEX IF NOT EXISTS resources_state ON resources(state);
            CREATE TABLE IF NOT EXISTS drive_assets (
                drive_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                completed_at REAL NOT NULL,
                modified_at REAL,
                PRIMARY KEY (drive_id, asset_id)
            );
            CREATE TABLE IF NOT EXISTS handled_paths (
                norm TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                resource_id TEXT,
                asset_id TEXT,
                on_drive INTEGER NOT NULL DEFAULT 0,
                on_bucket INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS handled_resource ON handled_paths(resource_id);
            CREATE INDEX IF NOT EXISTS handled_asset ON handled_paths(asset_id);
            CREATE TABLE IF NOT EXISTS remote_files (
                source TEXT NOT NULL,
                norm TEXT NOT NULL,
                path TEXT NOT NULL,
                size INTEGER NOT NULL,
                PRIMARY KEY (source, norm)
            );
            CREATE INDEX IF NOT EXISTS remote_files_norm ON remote_files(norm);
            CREATE TABLE IF NOT EXISTS imported_assets (
                asset_id TEXT PRIMARY KEY,
                tag TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TEMP TABLE library (id TEXT PRIMARY KEY);
            """)
        // Columns added before versions were recorded, which some databases lack whatever their version.
        do {
            db.addColumn("modified_at", definition: "REAL", to: "assets")
            db.addColumn("sha256", definition: "TEXT", to: "resources")
            db.addColumn("asset_modified_at", definition: "REAL", to: "resources")
            db.addColumn("on_bucket", definition: "INTEGER NOT NULL DEFAULT 0", to: "handled_paths")
            db.addColumn("superseded", definition: "INTEGER NOT NULL DEFAULT 0", to: "resources")
        }
        db.migrate(to: 1) {
            migrateToLibraryLayout(onLayoutChange)
        }
        recordWhatIsInBucket()
        recordWhereUploadsGo()
    }

    /// The layout changed from `<year>/<month>/<asset-uuid>/<file>` to the picture library's, so
    /// everything is backed up again.
    private func migrateToLibraryLayout(_ onLayoutChange: () -> Void) {
        execute("DELETE FROM resources")
        execute("DELETE FROM assets")
        execute("DELETE FROM drive_assets")
        onLayoutChange()
    }

    /// Files already uploaded from this phone are known to be in the bucket.
    private func recordWhatIsInBucket() {
        db.migrate(to: 2) {
            execute("UPDATE handled_paths SET on_bucket = 1 WHERE resource_id IN (SELECT id FROM resources WHERE state = ?)",
                    [ResourceState.done.rawValue])
        }
    }

    /// Each upload records the path and bucket it was sent to, so finishing it can only count for
    /// those. Uploads already going were sent to the path their file holds now.
    private func recordWhereUploadsGo() {
        db.migrate(to: 3) {
            db.addColumn("upload_path", definition: "TEXT", to: "resources")
            db.addColumn("upload_bucket", definition: "TEXT", to: "resources")
            execute("""
                UPDATE resources SET upload_path = (SELECT path FROM handled_paths WHERE handled_paths.resource_id = resources.id)
                WHERE state = ?
                """, [ResourceState.uploading.rawValue])
        }
    }

    // MARK: - Queries

    /// Completed assets mapped to the asset modification date they were backed up at
    /// (nil if unknown, which forces a recheck).
    public func completedAssets() -> [String: Double?] {
        locked { modifiedDates("SELECT id, modified_at FROM assets") }
    }

    public func count(_ state: ResourceState) -> Int {
        locked {
            query("SELECT COUNT(*) FROM resources WHERE state = ?", [state.rawValue]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    /// State and content hash of the last upload, by resource ID.
    public func resources(forAsset assetID: String) -> [String: (state: ResourceState, sha256: String?)] {
        locked {
            let rows = query("SELECT id, state, sha256 FROM resources WHERE asset_id = ?", [assetID]) {
                (text($0, 0) ?? "", (ResourceState(rawValue: Int(sqlite3_column_int($0, 1))) ?? .pending, text($0, 2)))
            }
            return Dictionary(rows, uniquingKeysWith: { $1 })
        }
    }

    public func uploadingResources() -> [(id: String, stagedName: String?)] {
        locked {
            query("SELECT id, staged_name FROM resources WHERE state = ?", [ResourceState.uploading.rawValue]) {
                (id: text($0, 0) ?? "", stagedName: text($0, 1))
            }
        }
    }

    public func stagedName(forResource id: String) -> String? {
        locked { query("SELECT staged_name FROM resources WHERE id = ?", [id]) { text($0, 0) }.first ?? nil }
    }

    public func lastError() -> String? {
        locked {
            query("SELECT last_error FROM resources WHERE state = ? ORDER BY updated_at DESC LIMIT 1",
                  [ResourceState.failed.rawValue]) { text($0, 0) }.first ?? nil
        }
    }

    // MARK: - Updates

    /// Records resources for an asset at its current modification date; keys of not-yet-uploaded
    /// resources are refreshed.
    public func register(_ rows: [ResourceRow], assetID: String, assetModifiedAt: Double?) {
        locked {
            for row in rows {
                execute("""
                    INSERT INTO resources (id, asset_id, s3_key, state, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET s3_key = excluded.s3_key WHERE state != \(ResourceState.done.rawValue)
                    """, [row.id, row.assetID, row.s3Key, ResourceState.pending.rawValue, now])
            }
            execute("UPDATE resources SET asset_modified_at = ? WHERE asset_id = ?", [assetModifiedAt, assetID])
        }
    }

    /// `path` and `bucket` are where the upload is going. Returns false, changing nothing, if the
    /// file has been forgotten or no longer holds `path` (another pass gave its photo new paths),
    /// in which case it mustn't be uploaded.
    public func markUploading(_ id: String, path: String, bucket: String, stagedName: String, sha256: String?) -> Bool {
        locked {
            guard holds(id, path) else { return false }
            execute("""
                UPDATE resources SET state = ?, staged_name = ?, sha256 = ?, superseded = 0, upload_path = ?, upload_bucket = ?, updated_at = ?
                WHERE id = ?
                """, [ResourceState.uploading.rawValue, stagedName, sha256, path, bucket, now, id])
            return true
        }
    }

    /// For an upload that has finished. It only counts for the path it was sent to: if the file no
    /// longer holds that path, it's put back to be sent to its new one.
    public func markDone(_ id: String) {
        locked {
            guard !resetSuperseded(id) else { return }
            guard let path = query("SELECT upload_path FROM resources WHERE id = ?", [id], { text($0, 0) }).first ?? nil else { return }
            guard done(id, path: path) else {
                execute("UPDATE resources SET state = ?, staged_name = NULL, updated_at = ? WHERE id = ? AND state = ?",
                        [ResourceState.pending.rawValue, now, id, ResourceState.uploading.rawValue])
                return
            }
        }
    }

    public func markFailed(_ id: String, error: String) {
        locked {
            execute("""
                UPDATE resources SET state = ?, staged_name = NULL, attempts = attempts + 1, last_error = ?, updated_at = ?
                WHERE id = ?
                """, [ResourceState.failed.rawValue, error, now, id])
        }
    }

    public func resetToPending(_ id: String) {
        locked {
            execute("UPDATE resources SET state = ?, staged_name = NULL, superseded = 0, updated_at = ? WHERE id = ?",
                    [ResourceState.pending.rawValue, now, id])
        }
    }

    /// For an upload that has finished: if it was going to a path its photo has since lost, puts
    /// it back to be sent to the new one, and returns true. How it finished doesn't matter then.
    public func resetIfSuperseded(_ id: String) -> Bool {
        locked { resetSuperseded(id) }
    }

    /// For assets with nothing to upload.
    public func markAssetComplete(_ assetID: String, modifiedAt: Double?) {
        locked {
            execute("INSERT OR REPLACE INTO assets (id, completed_at, modified_at) VALUES (?, ?, ?)", [assetID, now, modifiedAt])
        }
    }

    /// Forgets files an asset no longer has, such as an edit reverted before it could upload, which
    /// would otherwise keep the asset from ever being complete. Files that did upload stay on record.
    public func forgetMissingResources(forAsset assetID: String, keeping ids: [String]) {
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let args: [Any?] = [assetID, ResourceState.pending.rawValue, ResourceState.failed.rawValue] + ids
        locked { execute("DELETE FROM resources WHERE asset_id = ? AND state IN (?, ?) AND id NOT IN (\(marks))", args) }
    }

    /// Forgets files still waiting to upload whose photos have left the library (as listed by
    /// `setLibraryAssets`), which would otherwise count as failed on every pass. Does nothing until
    /// the library has been listed in this process, since until then every photo looks gone.
    public func forgetResourcesOfMissingAssets() {
        locked {
            guard libraryLoaded else { return }
            execute("DELETE FROM resources WHERE state IN (?, ?) AND asset_id NOT IN (SELECT id FROM library)",
                    [ResourceState.pending.rawValue, ResourceState.failed.rawValue])
        }
    }

    /// Marks the asset complete if every one of its resources has uploaded.
    public func markAssetCompleteIfFinished(_ assetID: String) {
        locked { completeAssetIfFinished(assetID) }
    }

    /// Forgets all history so everything is uploaded again (e.g. after switching buckets).
    public func reset() {
        locked { _ = handledTransaction { forgetBucketHistory() } }
    }

    /// Makes `identity` the bucket backed up to. Switching from another bucket forgets the history,
    /// as `reset` does, and the listing, so everything is checked against the new one and backed up
    /// to it. `olderForm` is how this bucket's identity used to be written, which isn't a switch.
    /// `listedKey` is the meta key saying when this bucket was last listed, which a listing of
    /// another one replaced. Returns whether the history was forgotten.
    public func useBucket(_ identity: String, olderForm: String, listedKey: String) throws -> Bool {
        try locked {
            let previous = query("SELECT value FROM meta WHERE key = 'current-bucket'") { text($0, 0) }.first ?? nil
            guard previous != identity else { return false }
            let forgets = previous != nil && previous != olderForm
            let saved = transaction {
                execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('current-bucket', ?)", [identity])
                guard forgets else { return }
                forgetBucketHistory()
                execute("DELETE FROM remote_files WHERE source = ?", [StorageSource.s3.rawValue])
                execute("DELETE FROM meta WHERE key = ?", [listedKey])
                bumpHandledVersion()
            }
            guard saved else { throw Failure.couldNotSave }
            return forgets
        }
    }

    private func forgetBucketHistory() {
        execute("DELETE FROM resources WHERE state != ?", [ResourceState.uploading.rawValue])
        // These can't be stopped, and may be headed for the old bucket, so finishing mustn't
        // count: they're sent again instead.
        execute("UPDATE resources SET superseded = 1 WHERE state = ?", [ResourceState.uploading.rawValue])
        execute("DELETE FROM assets")
        execute("UPDATE handled_paths SET on_bucket = 0 WHERE on_bucket != 0")
    }

    /// Nothing is known to be in a new bucket yet, so a file found at a photo's path has to be
    /// compared rather than assumed to be that photo.
    public func forgetBucketContents() {
        locked {
            execute("UPDATE handled_paths SET on_bucket = 0 WHERE on_bucket != 0")
            bumpHandledVersion()
        }
    }

    // MARK: - USB drive copies

    /// Assets copied to the drive, mapped to the asset modification date they were copied at.
    public func completedDriveAssets(driveID: String) -> [String: Double?] {
        locked { modifiedDates("SELECT asset_id, modified_at FROM drive_assets WHERE drive_id = ?", [driveID]) }
    }

    /// `files` are the asset's files that were copied, at their paths. Returns false, changing
    /// nothing, if any of them no longer holds its path.
    @discardableResult
    public func markDriveAssetComplete(_ assetID: String, driveID: String, modifiedAt: Double?, files: [ResourceRow]) -> Bool {
        locked {
            guard files.allSatisfy({ holder(ofPath: $0.path) == .resource($0.id) }) else { return false }
            execute("INSERT OR REPLACE INTO drive_assets (drive_id, asset_id, completed_at, modified_at) VALUES (?, ?, ?, ?)",
                    [driveID, assetID, now, modifiedAt])
            return true
        }
    }

    /// Forgets what was copied to drives other than `driveID` (all drives if nil).
    public func forgetDrives(except driveID: String?) {
        locked { execute("DELETE FROM drive_assets WHERE drive_id IS NOT ?", [driveID]) }
    }

    /// After changing folders: nothing is known to be in the new one yet, so a file found at a
    /// photo's path has to be compared rather than assumed to be that photo.
    public func forgetDriveContents() {
        locked {
            execute("UPDATE handled_paths SET on_drive = 0 WHERE on_drive != 0")
            execute("DELETE FROM remote_files WHERE source = ?", [StorageSource.drive.rawValue])
            bumpHandledVersion()
        }
    }

    // MARK: - Library paths

    /// The paths given to an asset's resources, by resource ID.
    public func paths(forAsset assetID: String) -> [String: String] {
        locked {
            let rows = query("SELECT resource_id, path FROM handled_paths WHERE asset_id = ? AND resource_id IS NOT NULL", [assetID]) {
                (text($0, 0) ?? "", text($0, 1) ?? "")
            }
            return Dictionary(rows, uniquingKeysWith: { $1 })
        }
    }

    public func pathHolder(_ path: String) -> PathHolder {
        locked { holder(ofPath: path) }
    }

    /// Lets go of a path whose resource is gone, such as after restoring to a phone where asset
    /// IDs differ. The path stays handled.
    public func releasePath(_ path: String) {
        locked { execute("UPDATE handled_paths SET resource_id = NULL, asset_id = NULL WHERE norm = ?", [LibraryPath.normalized(path)]) }
    }

    /// Gives paths to resources. Returns false, changing nothing, if another resource holds one of
    /// them, in which case the caller looks for different paths.
    public func claim(_ rows: [ResourceRow]) -> Bool {
        locked {
            for row in rows {
                if case let .resource(current) = holder(ofPath: row.path), current != row.id { return false }
            }
            return handledTransaction {
                for row in rows {
                    execute("""
                        INSERT INTO handled_paths (norm, path, kind, resource_id, asset_id) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(norm) DO UPDATE SET kind = excluded.kind, resource_id = excluded.resource_id, asset_id = excluded.asset_id
                        """, [LibraryPath.normalized(row.path), row.path, HandledPath.Kind.backup.rawValue, row.id, row.assetID])
                }
            }
        }
    }

    /// Takes an asset's paths away because something else turned out to be at one of them, so it
    /// gets new ones and is backed up again. The old paths stay handled: copies may already be
    /// there, and those must not be imported as if they were someone else's pictures.
    public func retirePaths(forAsset assetID: String) {
        locked { retire(assetID) }
    }

    private func retire(_ assetID: String) {
        _ = handledTransaction {
            execute("UPDATE handled_paths SET resource_id = NULL, asset_id = NULL, on_drive = 0, on_bucket = 0 WHERE asset_id = ?", [assetID])
            // Kept as pending so the asset can't count as complete until these are backed up again,
            // even if another of its files finishes uploading in the meantime.
            execute("UPDATE resources SET state = ?, staged_name = NULL WHERE asset_id = ? AND state != ?",
                    [ResourceState.pending.rawValue, assetID, ResourceState.uploading.rawValue])
            // These can't be stopped, and are headed for the old paths.
            execute("UPDATE resources SET superseded = 1 WHERE asset_id = ? AND state = ?",
                    [assetID, ResourceState.uploading.rawValue])
            execute("DELETE FROM assets WHERE id = ?", [assetID])
            execute("DELETE FROM drive_assets WHERE asset_id = ?", [assetID])
        }
    }

    /// `retirePaths` for an upload the bucket refused because the key already exists. All in one
    /// go, so another of the photo's files finishing can't complete it part way through.
    public func retirePaths(forResource resourceID: String) {
        locked {
            guard let assetID = query("SELECT asset_id FROM resources WHERE id = ?", [resourceID], { text($0, 0) }).first ?? nil else { return }
            execute("UPDATE resources SET state = ?, staged_name = NULL WHERE id = ?", [ResourceState.pending.rawValue, resourceID])
            retire(assetID)
        }
    }

    public func isOnDrive(_ path: String) -> Bool {
        locked {
            query("SELECT on_drive FROM handled_paths WHERE norm = ?", [LibraryPath.normalized(path)]) { sqlite3_column_int($0, 0) != 0 }.first ?? false
        }
    }

    public func isInBucket(_ path: String) -> Bool {
        locked {
            query("SELECT on_bucket FROM handled_paths WHERE norm = ?", [LibraryPath.normalized(path)]) { sqlite3_column_int($0, 0) != 0 }.first ?? false
        }
    }

    /// Records the file of resource `id` as on the drive at `path`. Returns false, changing
    /// nothing, if the resource no longer holds that path.
    @discardableResult
    public func markOnDrive(_ path: String, resource id: String) -> Bool {
        locked {
            // Only the path: the drive pass works without the bucket pass's rows.
            guard holder(ofPath: path) == .resource(id) else { return false }
            execute("UPDATE handled_paths SET on_drive = 1 WHERE norm = ? AND on_drive = 0", [LibraryPath.normalized(path)])
            if db.changes > 0 { bumpHandledVersion() }
            return true
        }
    }

    /// Records a file that turned out to be in the bucket already, at `path`. Returns false,
    /// changing nothing, if the file no longer holds that path.
    @discardableResult
    public func markDone(_ id: String, path: String, sha256: String?) -> Bool {
        locked {
            guard holds(id, path) else { return false }
            execute("UPDATE resources SET sha256 = ? WHERE id = ?", [sha256, id])
            return done(id, path: path)
        }
    }

    /// Normalized forms of every path that's been backed up or imported.
    public func handledPaths() -> Set<String> {
        locked { Set(query("SELECT norm FROM handled_paths") { text($0, 0) ?? "" }) }
    }

    public func handledEntries() -> [HandledPath] {
        locked { handledRows() }
    }

    private func handledRows() -> [HandledPath] {
        query("SELECT path, kind, resource_id, on_drive, on_bucket FROM handled_paths") { stmt in
            HandledPath(
                path: text(stmt, 0) ?? "",
                kind: HandledPath.Kind(rawValue: text(stmt, 1) ?? "") ?? .backup,
                resourceID: text(stmt, 2),
                onDrive: sqlite3_column_int(stmt, 3) != 0 ? true : nil,
                inBucket: sqlite3_column_int(stmt, 4) != 0 ? true : nil
            )
        }
    }

    /// Adds entries read from a file in `source`. Paths already known keep what's known about them.
    /// A file only speaks for where it was found: the copy in the bucket says what's in that bucket,
    /// not what's on whichever drive is plugged in now.
    public func mergeHandled(_ entries: [HandledPath], from source: StorageSource) -> Bool {
        guard !entries.isEmpty else { return true }
        return locked {
            handledTransaction {
                try insert("""
                    INSERT INTO handled_paths (norm, path, kind, resource_id, asset_id, on_drive, on_bucket) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(norm) DO UPDATE SET on_drive = MAX(on_drive, excluded.on_drive), on_bucket = MAX(on_bucket, excluded.on_bucket)
                    """, rows: entries) { stmt, entry in
                    SQLiteDatabase.bind(stmt, 1, LibraryPath.normalized(entry.path))
                    SQLiteDatabase.bind(stmt, 2, entry.path)
                    SQLiteDatabase.bind(stmt, 3, entry.kind.rawValue)
                    SQLiteDatabase.bind(stmt, 4, entry.resourceID)
                    SQLiteDatabase.bind(stmt, 5, entry.resourceID.map(ResourceRow.assetID(ofResource:)))
                    sqlite3_bind_int(stmt, 6, source == .drive && entry.onDrive == true ? 1 : 0)
                    sqlite3_bind_int(stmt, 7, source == .s3 && entry.inBucket == true ? 1 : 0)
                }
            }
        }
    }

    /// The handled paths with the version they're at, read together.
    public func handledSnapshot() -> (version: Int, entries: [HandledPath]) {
        locked {
            let version = query("SELECT value FROM meta WHERE key = 'handled_version'") { Int(text($0, 0) ?? "") ?? 0 }.first ?? 0
            return (version, handledRows())
        }
    }

    private func bumpHandledVersion() {
        let current = query("SELECT value FROM meta WHERE key = 'handled_version'") { Int(text($0, 0) ?? "") ?? 0 }.first ?? 0
        execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('handled_version', ?)", [String(current + 1)])
    }

    /// Goes up each time the handled paths change, to tell when copies in storage are out of date.
    public var handledVersion: Int {
        Int(meta("handled_version") ?? "") ?? 0
    }

    public func meta(_ key: String) -> String? {
        locked { query("SELECT value FROM meta WHERE key = ?", [key]) { text($0, 0) }.first ?? nil }
    }

    public func setMeta(_ key: String, _ value: String) {
        locked { execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value]) }
    }

    // MARK: - What's in storage

    /// Returns false, keeping the previous listing, if it couldn't be saved.
    public func replaceInventory(source: StorageSource, entries: [InventoryEntry]) -> Bool {
        locked {
            transaction {
                execute("DELETE FROM remote_files WHERE source = ?", [source.rawValue])
                try insertInventory(source: source, entries: entries)
            }
        }
    }

    /// Adds part of a listing that's saved as it goes. `replacingFolder` starts that folder's
    /// listing over, forgetting the files directly in it ("" is the top). Returns false, changing
    /// nothing, if it couldn't be saved.
    public func addInventory(source: StorageSource, entries: [InventoryEntry], replacingFolder folder: String? = nil) -> Bool {
        locked {
            transaction {
                if let folder { deleteInventory(source: source, folder: LibraryPath.normalized(folder)) }
                try insertInventory(source: source, entries: entries)
            }
        }
    }

    private func insertInventory(source: StorageSource, entries: [InventoryEntry]) throws {
        try insert("INSERT OR REPLACE INTO remote_files (source, norm, path, size) VALUES (?, ?, ?, ?)", [source.rawValue], rows: entries) { stmt, entry in
            SQLiteDatabase.bind(stmt, 2, LibraryPath.normalized(entry.path))
            SQLiteDatabase.bind(stmt, 3, entry.path)
            sqlite3_bind_int64(stmt, 4, entry.size)
        }
    }

    /// Forgets the files in every folder but `folders`, once a listing saved as it went has
    /// finished. Only files directly in a folder count as in it; "" is the top.
    public func keepInventory(source: StorageSource, onlyInFolders folders: Set<String>) -> Bool {
        let keep = Set(folders.map(LibraryPath.normalized))
        return locked {
            let present = Set(query("SELECT norm FROM remote_files WHERE source = ?", [source.rawValue]) { text($0, 0) ?? "" }
                .map { ($0 as NSString).deletingLastPathComponent })
            return transaction {
                for folder in present.subtracting(keep) { deleteInventory(source: source, folder: folder) }
            }
        }
    }

    /// `folder` is normalized.
    private func deleteInventory(source: StorageSource, folder: String) {
        if folder.isEmpty {
            execute("DELETE FROM remote_files WHERE source = ? AND instr(norm, '/') = 0", [source.rawValue])
        } else {
            // SQLite counts characters as code points.
            let length = folder.unicodeScalars.count
            execute("DELETE FROM remote_files WHERE source = ? AND substr(norm, 1, ?) = ? AND instr(substr(norm, ?), '/') = 0",
                    [source.rawValue, length + 1, folder + "/", length + 2])
        }
    }

    public func inventory() -> [InventoryEntry] {
        locked {
            query("SELECT source, path, size FROM remote_files", [], inventoryEntry)
        }
    }

    /// Where a path is known to exist, with its exact spelling and size there.
    public func inventoryEntries(for path: String) -> [InventoryEntry] {
        locked {
            query("SELECT source, path, size FROM remote_files WHERE norm = ?", [LibraryPath.normalized(path)], inventoryEntry)
        }
    }

    // MARK: - Imported photos

    public func importedAssetIDs() -> Set<String> {
        locked { Set(query("SELECT asset_id FROM imported_assets") { text($0, 0) ?? "" }) }
    }

    /// A few of the imported IDs, to check that they still match the library.
    public func sampleImportedAssetIDs(limit: Int) -> [String] {
        locked { query("SELECT asset_id FROM imported_assets LIMIT ?", [limit]) { text($0, 0) ?? "" } }
    }

    public func importedTags() -> Set<String> {
        locked { Set(query("SELECT tag FROM imported_assets") { text($0, 0) ?? "" }) }
    }

    public func recordImports(_ imports: [(assetID: String, path: String)]) -> Bool {
        guard !imports.isEmpty else { return true }
        return locked {
            handledTransaction {
                for item in imports {
                    execute("INSERT OR REPLACE INTO imported_assets (asset_id, tag) VALUES (?, ?)", [item.assetID, LibraryPath.tag(for: item.path)])
                    addImportedPath(item.path)
                }
            }
        }
    }

    /// Replaces the record of imports with what was found in the Photos library.
    public func replaceImportedAssets(_ assets: [(assetID: String, tag: String)]) -> Bool {
        locked {
            transaction {
                execute("DELETE FROM imported_assets")
                try insert("INSERT OR REPLACE INTO imported_assets (asset_id, tag) VALUES (?, ?)", rows: assets) { stmt, asset in
                    SQLiteDatabase.bind(stmt, 1, asset.assetID)
                    SQLiteDatabase.bind(stmt, 2, asset.tag)
                }
            }
        }
    }

    /// Marks paths as dealt with because a copy of them was found in the Photos library.
    public func markImported(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return true }
        return locked {
            handledTransaction {
                for path in paths { addImportedPath(path) }
            }
        }
    }

    // MARK: - Coverage

    /// How many photos in the library are backed up where.
    public struct Coverage: Equatable, Codable, Sendable {
        public var total: Int
        public var cloud: Int
        public var drive: Int
        public var both: Int

        public init(total: Int = 0, cloud: Int = 0, drive: Int = 0, both: Int = 0) {
            self.total = total
            self.cloud = cloud
            self.drive = drive
            self.both = both
        }

        public var cloudOnly: Int { cloud - both }
        public var driveOnly: Int { drive - both }
        public var nowhere: Int { total - cloud - drive + both }
    }

    /// Replaces the IDs of the assets currently in the photo library, which `coverage` counts
    /// against (so deleted photos aren't counted).
    public func setLibraryAssets(_ ids: [String]) {
        locked {
            let saved = transaction {
                execute("DELETE FROM library")
                try insert("INSERT OR IGNORE INTO library (id) VALUES (?)", rows: ids) { stmt, id in
                    SQLiteDatabase.bind(stmt, 1, id)
                }
            }
            if saved { libraryLoaded = true }
        }
    }

    /// Nil until the library has been listed, when every count would be zero.
    public func coverage(driveID: String?) -> Coverage? {
        locked {
            guard libraryLoaded else { return nil }
            return query("""
                SELECT COUNT(*), COUNT(a.id), COUNT(d.asset_id), SUM(a.id IS NOT NULL AND d.asset_id IS NOT NULL)
                FROM library l
                LEFT JOIN assets a ON a.id = l.id
                LEFT JOIN drive_assets d ON d.drive_id = ? AND d.asset_id = l.id
                """, [driveID]) {
                Coverage(total: Int(sqlite3_column_int64($0, 0)), cloud: Int(sqlite3_column_int64($0, 1)),
                         drive: Int(sqlite3_column_int64($0, 2)), both: Int(sqlite3_column_int64($0, 3)))
            }.first ?? Coverage()
        }
    }

    // MARK: - SQLite helpers (call with lock held)

    private var now: Double { Date().timeIntervalSince1970 }

    private func resetSuperseded(_ id: String) -> Bool {
        let superseded = query("SELECT superseded FROM resources WHERE id = ?", [id]) { sqlite3_column_int($0, 0) != 0 }.first ?? false
        guard superseded else { return false }
        execute("UPDATE resources SET state = ?, staged_name = NULL, superseded = 0, updated_at = ? WHERE id = ?",
                [ResourceState.pending.rawValue, now, id])
        return true
    }

    private func holder(ofPath path: String) -> PathHolder {
        let rows: [String?] = query("SELECT resource_id FROM handled_paths WHERE norm = ?", [LibraryPath.normalized(path)]) { text($0, 0) }
        guard let row = rows.first else { return .free }
        return row.map(PathHolder.resource) ?? .released
    }

    private func addImportedPath(_ path: String) {
        execute("INSERT OR IGNORE INTO handled_paths (norm, path, kind) VALUES (?, ?, ?)",
                [LibraryPath.normalized(path), path, HandledPath.Kind.import.rawValue])
    }

    private func inventoryEntry(_ stmt: OpaquePointer) -> InventoryEntry {
        InventoryEntry(source: StorageSource(rawValue: text(stmt, 0) ?? "") ?? .drive, path: text(stmt, 1) ?? "", size: sqlite3_column_int64(stmt, 2))
    }

    /// `path` is where the file is in the bucket. Nothing counts for a file that's been forgotten,
    /// such as by `reset` between registering and uploading it, so what's at its path isn't taken
    /// for the photo's own.
    /// Whether resource `id` is on record and still holds `path`.
    private func holds(_ id: String, _ path: String) -> Bool {
        holder(ofPath: path) == .resource(id)
            && !query("SELECT 1 FROM resources WHERE id = ?", [id], { _ in true }).isEmpty
    }

    /// Returns false, changing nothing, if the resource has been forgotten or no longer holds `path`.
    @discardableResult
    private func done(_ id: String, path: String) -> Bool {
        guard holds(id, path),
              let assetID = query("SELECT asset_id FROM resources WHERE id = ?", [id], { text($0, 0) }).first ?? nil
        else { return false }
        execute("UPDATE resources SET state = ?, staged_name = NULL, last_error = NULL, updated_at = ? WHERE id = ?",
                [ResourceState.done.rawValue, now, id])
        execute("UPDATE handled_paths SET on_bucket = 1 WHERE norm = ? AND resource_id = ? AND on_bucket = 0",
                [LibraryPath.normalized(path), id])
        if db.changes > 0 { bumpHandledVersion() }
        completeAssetIfFinished(assetID)
        return true
    }

    /// Asset IDs mapped to the modification dates in the second column, which may be null.
    private func modifiedDates(_ sql: String, _ args: [Any?] = []) -> [String: Double?] {
        let rows = query(sql, args) { stmt -> (String, Double?) in
            let modified = SQLiteDatabase.double(stmt, 1)
            return (text(stmt, 0) ?? "", modified)
        }
        return Dictionary(rows, uniquingKeysWith: { $1 })
    }

    private func completeAssetIfFinished(_ assetID: String) {
        let remaining = query("SELECT COUNT(*) FROM resources WHERE asset_id = ? AND state != ?",
                              [assetID, ResourceState.done.rawValue]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard remaining == 0 else { return }
        execute("""
            INSERT OR REPLACE INTO assets (id, completed_at, modified_at)
            SELECT ?, ?, MAX(asset_modified_at) FROM resources WHERE asset_id = ?
            """, [assetID, now, assetID])
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { try db.locked(body) }

    private func transaction(_ body: () throws -> Void) -> Bool { db.transaction(body) }

    private func execute(_ sql: String, _ args: [Any?] = []) { db.execute(sql, args) }

    private func query<T>(_ sql: String, _ args: [Any?] = [], _ row: (OpaquePointer) -> T) -> [T] { db.query(sql, args, row) }

    private func insert<Row>(_ sql: String, _ args: [Any?] = [], rows: [Row], bind: (OpaquePointer, Row) -> Void) throws {
        try db.insert(sql, args, rows: rows, bind: bind)
    }

    private func text(_ stmt: OpaquePointer, _ column: Int32) -> String? { SQLiteDatabase.text(stmt, column) }

    /// A transaction that changes the handled paths.
    private func handledTransaction(_ body: () throws -> Void) -> Bool {
        let saved = transaction(body)
        if saved { bumpHandledVersion() }
        return saved
    }
}

extension BackupStore {
    public enum Failure: Error, LocalizedError {
        case couldNotSave

        public var errorDescription: String? {
            "Couldn't save the record of what's in storage. This phone may be out of space."
        }
    }
}
