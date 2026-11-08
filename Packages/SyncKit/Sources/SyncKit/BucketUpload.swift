import Foundation

/// What staging a file for the bucket does with what's already at its path.
public struct BucketUpload: Equatable, Sendable {
    /// What's at the path is this photo's own file, from an earlier upload to this bucket.
    public let isOwn: Bool
    /// What's at the path has to be compared with the photo before anything is sent.
    public let compares: Bool
    /// The upload asks the bucket to refuse it if the name is taken. Only this photo's own older
    /// edit gets replaced.
    public let mustNotExist: Bool

    /// `previous` is the file's state in the history, `knownInBucket` whether its path is recorded
    /// as holding its file in the bucket, and `inListing` whether the bucket's listing has something
    /// at the path.
    public init(previous: ResourceState?, knownInBucket: Bool, inListing: Bool, isEdit: Bool, conditionalWrites: Bool) {
        // Having a path doesn't mean what's there is this photo's: it may have been chosen on a
        // pass to the drive, or before switching buckets.
        isOwn = previous == .done || knownInBucket
        compares = previous != .done && inListing
        mustNotExist = conditionalWrites && (!isEdit || !isOwn)
    }
}
