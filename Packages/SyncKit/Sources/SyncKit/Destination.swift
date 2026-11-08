import Foundation

/// A place backups go, named by what tells it apart: a drive folder's ID, or a bucket's identity
/// (service, bucket and prefix). Everything kept about a destination in `meta` is under keys made
/// here, so all of it can be found, and removed, together.
public enum Destination: Hashable, Sendable {
    case drive(String)
    case bucket(String)

    /// Where the listing of it is kept: a drive's progress, or when a bucket was last listed.
    public var listingKey: String {
        switch self {
        case .drive(let id): "drive-listing-\(id)"
        case .bucket(let identity): "listed-s3-\(identity)"
        }
    }

    /// Set once the handled paths already there have been merged in.
    public var mergedKey: String {
        switch self {
        case .drive(let id): "merged-drive-\(id)"
        case .bucket(let identity): "merged-s3-\(identity)"
        }
    }

    /// The version of the handled paths last written there. `HandledPathsWriter` also keeps when,
    /// under this plus `-at`.
    public var writtenKey: String {
        switch self {
        case .drive(let id): "written-drive-\(id)"
        case .bucket(let identity): "written-s3-\(identity)"
        }
    }

    /// The last answer on whether a bucket can refuse an upload to a taken name, and when it was asked.
    public var conditionalWritesKey: String {
        switch self {
        case .drive(let id): "conditional-writes-drive-\(id)"
        case .bucket(let identity): "conditional-writes-\(identity)"
        }
    }

    /// Set when the answer is known to be out of date, until the bucket is asked again.
    public var recheckConditionalWritesKey: String {
        "recheck-conditional-writes-\(name)"
    }

    private var name: String {
        switch self {
        case .drive(let id): "drive-\(id)"
        case .bucket(let identity): "s3-\(identity)"
        }
    }

    /// Every meta key kept for it.
    public var metaKeys: [String] {
        [listingKey, "\(listingKey)-finished", mergedKey, writtenKey, "\(writtenKey)-at",
         conditionalWritesKey, recheckConditionalWritesKey]
    }
}
