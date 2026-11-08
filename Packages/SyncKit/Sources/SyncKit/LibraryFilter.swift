import Foundation

/// What the app needs to know about one asset in the photo library, as plain values, so that deciding
/// who gets which assets can be tested without PhotoKit.
public struct LibraryEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case image, video, other }

    public let id: String
    public let kind: Kind
    public let created: Date?
    /// Seconds since 1970.
    public let modified: Double?
    public let isHidden: Bool
    public let isScreenshot: Bool
    /// A shot of a burst other than the one that stands for the burst in the library.
    public let isExtraBurstShot: Bool
    public let latitude: Double?
    public let longitude: Double?

    public init(id: String, kind: Kind = .image, created: Date? = nil, modified: Double? = nil,
                isHidden: Bool = false, isScreenshot: Bool = false, isExtraBurstShot: Bool = false,
                latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.kind = kind
        self.created = created
        self.modified = modified
        self.isHidden = isHidden
        self.isScreenshot = isScreenshot
        self.isExtraBurstShot = isExtraBurstShot
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Which entries of one library snapshot each user wants. Each returns indices into `entries`, in
/// order, so the caller can pick the matching assets.
public enum LibraryFilter {
    /// Entries that need backing up, given `completed` (asset ID → the asset's modification date when
    /// it was backed up). New ones are included, plus completed ones modified since (e.g. edited),
    /// and ones whose date is unknown on either side.
    public static func pending(_ entries: [LibraryEntry], completed: [String: Double?]) -> [Int] {
        entries.indices.filter { index in
            let entry = entries[index]
            guard let backedUpAt = completed[entry.id] else { return true }
            if let backedUpAt, let modified = entry.modified, modified <= backedUpAt { return false }
            return true
        }
    }

    /// Photos that can belong to a trip: visible, dated, and not screenshots. Bursts count once.
    public static func tripPhotos(_ entries: [LibraryEntry]) -> [Int] {
        entries.indices.filter { index in
            let entry = entries[index]
            return entry.kind == .image && !entry.isHidden && !entry.isExtraBurstShot
                && !entry.isScreenshot && entry.created != nil
        }
    }

    /// Visible still photos, including every shot of each burst.
    public static func burstShots(_ entries: [LibraryEntry]) -> [Int] {
        entries.indices.filter { entries[$0].kind == .image && !entries[$0].isHidden }
    }
}
