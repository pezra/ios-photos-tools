import Foundation

/// A photo to consider for grouping: what the analysis learned about it, plus library details
/// that can change without the pixels changing.
public struct DuplicateCandidate: Sendable {
    public let id: String
    public let createdAt: Date?
    public let isFavorite: Bool
    public let isEdited: Bool
    public let burstID: String?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Difference hash of a small greyscale copy.
    public let dHash: UInt64
    /// Unit-length feature print.
    public let featurePrint: [Float]
    public let aesthetics: Float
    public let faceQuality: Float?
    public let sharpness: Double

    public init(id: String, createdAt: Date?, isFavorite: Bool, isEdited: Bool, burstID: String?,
                pixelWidth: Int, pixelHeight: Int, dHash: UInt64, featurePrint: [Float],
                aesthetics: Float, faceQuality: Float?, sharpness: Double) {
        self.id = id
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.isEdited = isEdited
        self.burstID = burstID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dHash = dHash
        self.featurePrint = featurePrint
        self.aesthetics = aesthetics
        self.faceQuality = faceQuality
        self.sharpness = sharpness
    }
}

/// Photos that look like the same shot, best first.
public struct DuplicateGroup: Identifiable, Sendable {
    public let assetIDs: [String]

    public init(assetIDs: [String]) { self.assetIDs = assetIDs }

    public var id: String { assetIDs[0] }
    public var best: String { assetIDs[0] }
}

public enum DuplicateGrouper {
    public struct Options: Sendable {
        /// Only photos taken within this many seconds of each other are compared (exact copies
        /// are found regardless).
        public var window: TimeInterval = 120
        /// Largest feature-print distance (0–2) still counted as the same shot.
        public var maxFeatureDistance: Float = 0.45
        /// Largest difference-hash distance (bits out of 64) counted as the same image.
        public var maxHashDistance = 4

        public init() {}
    }

    /// Groups of two or more near-identical photos, newest first, each ranked best first.
    public static func groups(_ candidates: [DuplicateCandidate], options: Options = Options()) -> [DuplicateGroup] {
        var clusters = timeClusters(candidates, options: options)
        clusters = mergingCopies(clusters, options: options)
        return clusters
            .filter { $0.count > 1 }
            .map { (newest: $0.compactMap(\.createdAt).max() ?? .distantPast, cluster: $0) }
            .sorted { $0.newest > $1.newest }
            .map { DuplicateGroup(assetIDs: rank($0.cluster).map(\.id)) }
    }

    /// Best photo first: favourites, then by a blend of aesthetics, face quality and sharpness.
    public static func rank(_ group: [DuplicateCandidate]) -> [DuplicateCandidate] {
        let sharpest = group.map(\.sharpness).max() ?? 0
        func score(_ c: DuplicateCandidate) -> Double {
            var score = Double(c.aesthetics)
            score += 0.5 * Double(c.faceQuality ?? 0)
            // Relative within the group: absolute sharpness depends too much on content.
            if sharpest > 0 { score += 0.4 * (c.sharpness / sharpest) }
            if c.isEdited { score += 0.2 }
            return score
        }
        return group
            .map { (candidate: $0, score: score($0)) }
            .sorted { lhs, rhs in
                if lhs.candidate.isFavorite != rhs.candidate.isFavorite { return lhs.candidate.isFavorite }
                return lhs.score > rhs.score
            }
            .map(\.candidate)
    }

    public static func areSimilar(_ a: DuplicateCandidate, _ b: DuplicateCandidate, options: Options) -> Bool {
        if let burst = a.burstID, burst == b.burstID { return true }
        if (a.dHash ^ b.dHash).nonzeroBitCount <= options.maxHashDistance { return true }
        return FeaturePrint.distance(a.featurePrint, b.featurePrint) <= options.maxFeatureDistance
    }

    // MARK: - Steps

    /// Walks the photos in capture order, adding each to the nearby cluster it's most similar to.
    /// A photo joins only if it resembles every member already there, so a slow pan doesn't chain
    /// into one huge group.
    private static func timeClusters(_ candidates: [DuplicateCandidate], options: Options) -> [[DuplicateCandidate]] {
        let dated = candidates.filter { $0.createdAt != nil }.sorted { $0.createdAt! < $1.createdAt! }
        var clusters = candidates.filter { $0.createdAt == nil }.map { [$0] }

        var open: [[DuplicateCandidate]] = []
        for candidate in dated {
            let time = candidate.createdAt!
            // Close clusters whose newest photo is out of range; nothing later can join them.
            let (stale, live) = open.partitioned { time.timeIntervalSince($0.last!.createdAt!) > options.window }
            clusters += stale
            open = live

            let best = open.indices
                .filter { i in open[i].allSatisfy { areSimilar($0, candidate, options: options) } }
                .min { worstDistance(open[$0], candidate) < worstDistance(open[$1], candidate) }
            if let best {
                open[best].append(candidate)
            } else {
                open.append([candidate])
            }
        }
        return clusters + open
    }

    /// Joins clusters holding byte-for-byte-looking copies (same hash and size), however far
    /// apart they were taken, e.g. a photo imported twice or saved from a message.
    private static func mergingCopies(_ clusters: [[DuplicateCandidate]], options: Options) -> [[DuplicateCandidate]] {
        var parent = Array(clusters.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }

        struct CopyKey: Hashable { let hash: UInt64; let width: Int; let height: Int }
        var firstCluster: [CopyKey: (cluster: Int, candidate: DuplicateCandidate)] = [:]
        for (index, cluster) in clusters.enumerated() {
            for candidate in cluster {
                let key = CopyKey(hash: candidate.dHash, width: candidate.pixelWidth, height: candidate.pixelHeight)
                guard let first = firstCluster[key] else {
                    firstCluster[key] = (index, candidate)
                    continue
                }
                // Featureless images (all black, all sky) can share a hash; make sure they match.
                if FeaturePrint.distance(first.candidate.featurePrint, candidate.featurePrint) <= options.maxFeatureDistance / 3 {
                    parent[root(index)] = root(first.cluster)
                }
            }
        }

        var merged: [Int: [DuplicateCandidate]] = [:]
        for (index, cluster) in clusters.enumerated() { merged[root(index), default: []] += cluster }
        return Array(merged.values)
    }

    private static func worstDistance(_ cluster: [DuplicateCandidate], _ candidate: DuplicateCandidate) -> Float {
        cluster.map { FeaturePrint.distance($0.featurePrint, candidate.featurePrint) }.max() ?? 0
    }
}

private extension Array {
    func partitioned(by isFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if isFirst(element) { first.append(element) } else { second.append(element) }
        }
        return (first, second)
    }
}
