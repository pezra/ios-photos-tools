import Foundation

public enum StorageSource: String, Sendable {
    case drive
    case s3
}

/// A file found in storage.
public struct InventoryEntry: Sendable, Equatable {
    public var source: StorageSource
    public var path: String
    public var size: Int64

    public init(source: StorageSource, path: String, size: Int64) {
        self.source = source
        self.path = path
        self.size = size
    }
}

/// A picture to copy to the phone, and where it can be read from.
public struct ImportCandidate: Sendable, Equatable {
    public var path: String
    /// The exact spelling in each place it can be read from, since the two can differ and bucket
    /// keys are case-sensitive.
    public var drivePath: String?
    public var s3Path: String?

    public var onDrive: Bool { drivePath != nil }
    public var onS3: Bool { s3Path != nil }
}

public enum ImportPlanner {
    /// The pictures in storage that haven't been dealt with, newest folders first.
    ///
    /// A picture is skipped if it's in `handled` (it was backed up from this phone or imported, even
    /// if the photo has since been deleted, so deleted photos stay gone) or its tag is in
    /// `importedTags` (a copy of it is in the Photos library).
    public static func candidates(
        from entries: [InventoryEntry],
        handled: Set<String>,
        importedTags: Set<String>
    ) -> [ImportCandidate] {
        var byPath: [String: ImportCandidate] = [:]
        for entry in entries where LibraryPath.isImportable(entry.path) {
            let key = LibraryPath.normalized(entry.path)
            guard !handled.contains(key) else { continue }
            var candidate = byPath[key] ?? ImportCandidate(path: entry.path)
            switch entry.source {
            case .drive: candidate.drivePath = entry.path
            case .s3: candidate.s3Path = entry.path
            }
            byPath[key] = candidate
        }
        return byPath.values
            .filter { !importedTags.contains(LibraryPath.tag(for: $0.path)) }
            .sorted { $0.path > $1.path }
    }
}
