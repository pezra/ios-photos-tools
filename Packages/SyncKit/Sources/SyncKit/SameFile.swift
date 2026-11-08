import Foundation

/// Whether a photo's file is the file already in storage at its path, going by size where that's
/// enough. A file with the same name and exact size is taken to be the same file.
public enum SameFile: Equatable, Sendable {
    /// The same file. Nothing needs reading.
    case same
    /// A different picture, which gets the next free name.
    case different
    /// Can't tell from sizes: the photo has to be read and compared with what's in storage.
    case compare

    /// `photoSize` is the size of the photo's file if it can be known without reading it, and
    /// `storedSizes` the size of the copy at the path in each place that has one (drive, bucket).
    ///
    /// An edit keeps its name when re-edited, so its name says nothing about its content and it is
    /// always compared in full.
    public static func decide(isEdit: Bool, photoSize: Int64?, storedSizes: [Int64]) -> SameFile {
        guard !isEdit, let photoSize, !storedSizes.isEmpty else { return .compare }
        return storedSizes.allSatisfy { $0 == photoSize } ? .same : .different
    }
}
