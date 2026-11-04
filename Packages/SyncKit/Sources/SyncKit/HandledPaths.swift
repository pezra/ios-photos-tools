import Foundation

/// A path that has been backed up from the phone or imported to it. Kept next to the backups, so
/// what's been dealt with (including photos since deleted) survives reinstalling the app.
public struct HandledPath: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case backup
        case `import`
    }

    public var path: String
    public var kind: Kind
    /// For backups: the resource this path belongs to, while this phone still has its asset.
    public var resourceID: String?
    /// For backups: the file is known to be on the drive, so it needn't be compared again.
    public var onDrive: Bool?

    public init(path: String, kind: Kind, resourceID: String? = nil, onDrive: Bool? = nil) {
        self.path = path
        self.kind = kind
        self.resourceID = resourceID
        self.onDrive = onDrive
    }
}

/// The `.photos-tools/handled-paths.jsonl` file, one JSON object per line.
public enum HandledPathsFile {
    public static let relativePath = ".photos-tools/handled-paths.jsonl"

    public static func encode(_ entries: [HandledPath]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var data = Data()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    /// Lines that can't be read are skipped, so damage to the file loses only those lines.
    public static func decode(_ data: Data) -> [HandledPath] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(HandledPath.self, from: Data($0)) }
    }

    /// Combines copies of the file. Paths are only ever added, so the union is always right and one
    /// copy being stale or missing does no harm.
    public static func merge(_ copies: [HandledPath]...) -> [HandledPath] {
        var merged: [String: HandledPath] = [:]
        for entry in copies.joined() {
            let key = LibraryPath.normalized(entry.path)
            guard var existing = merged[key] else {
                merged[key] = entry
                continue
            }
            existing.resourceID = existing.resourceID ?? entry.resourceID
            if entry.onDrive == true { existing.onDrive = true }
            if entry.kind == .backup { existing.kind = .backup }
            merged[key] = existing
        }
        return Array(merged.values)
    }
}
