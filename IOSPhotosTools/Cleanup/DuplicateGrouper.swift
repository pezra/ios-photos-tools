import Foundation
import Photos
import TripKit

/// A photo to consider for grouping: its analysis plus library details that can change without
/// the pixels changing.
struct Candidate: Sendable {
    let analysis: PhotoAnalysis
    let createdAt: Date?
    let isFavorite: Bool
    let isEdited: Bool
    let burstID: String?

    var id: String { analysis.assetID }
}

extension Candidate {
    init(analysis: PhotoAnalysis, asset: PHAsset) {
        self.init(analysis: analysis, createdAt: asset.creationDate, isFavorite: asset.isFavorite,
                  isEdited: asset.hasAdjustments, burstID: asset.burstIdentifier)
    }
}

/// Photos that look like the same shot, best first.
struct DuplicateGroup: Identifiable, Sendable {
    let assetIDs: [String]

    var id: String { assetIDs[0] }
    var best: String { assetIDs[0] }
}

enum DuplicateGrouper {
    struct Options: Sendable {
        /// Only photos taken within this many seconds of each other are compared (exact copies
        /// are found regardless).
        var window: TimeInterval = 120
        /// Largest feature-print distance (0–2) still counted as the same shot.
        var maxFeatureDistance: Float = 0.45
        /// Largest difference-hash distance (bits out of 64) counted as the same image.
        var maxHashDistance = 4
    }

    /// Groups of two or more near-identical photos, newest first, each ranked best first.
    static func groups(_ candidates: [Candidate], options: Options = Options()) -> [DuplicateGroup] {
        var clusters = timeClusters(candidates, options: options)
        clusters = mergingCopies(clusters, options: options)
        return clusters
            .filter { $0.count > 1 }
            .map { (newest: $0.compactMap(\.createdAt).max() ?? .distantPast, cluster: $0) }
            .sorted { $0.newest > $1.newest }
            .map { DuplicateGroup(assetIDs: rank($0.cluster).map(\.id)) }
    }

    /// Best photo first: favourites, then by a blend of aesthetics, face quality and sharpness.
    static func rank(_ group: [Candidate]) -> [Candidate] {
        let sharpest = group.map(\.analysis.sharpness).max() ?? 0
        func score(_ c: Candidate) -> Double {
            let a = c.analysis
            var score = Double(a.aesthetics)
            score += 0.5 * Double(a.faceQuality ?? 0)
            // Relative within the group: absolute sharpness depends too much on content.
            if sharpest > 0 { score += 0.4 * (a.sharpness / sharpest) }
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

    static func areSimilar(_ a: Candidate, _ b: Candidate, options: Options) -> Bool {
        if let burst = a.burstID, burst == b.burstID { return true }
        if ImageMetrics.hammingDistance(a.analysis.dHash, b.analysis.dHash) <= options.maxHashDistance { return true }
        return FeaturePrint.distance(a.analysis.featurePrint, b.analysis.featurePrint) <= options.maxFeatureDistance
    }

    // MARK: - Steps

    /// Walks the photos in capture order, adding each to the nearby cluster it's most similar to.
    /// A photo joins only if it resembles every member already there, so a slow pan doesn't chain
    /// into one huge group.
    private static func timeClusters(_ candidates: [Candidate], options: Options) -> [[Candidate]] {
        let dated = candidates.filter { $0.createdAt != nil }.sorted { $0.createdAt! < $1.createdAt! }
        var clusters = candidates.filter { $0.createdAt == nil }.map { [$0] }

        var open: [[Candidate]] = []
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
    private static func mergingCopies(_ clusters: [[Candidate]], options: Options) -> [[Candidate]] {
        var parent = Array(clusters.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }

        struct CopyKey: Hashable { let hash: UInt64; let width: Int; let height: Int }
        var firstCluster: [CopyKey: (cluster: Int, candidate: Candidate)] = [:]
        for (index, cluster) in clusters.enumerated() {
            for candidate in cluster {
                let a = candidate.analysis
                let key = CopyKey(hash: a.dHash, width: a.pixelWidth, height: a.pixelHeight)
                guard let first = firstCluster[key] else {
                    firstCluster[key] = (index, candidate)
                    continue
                }
                // Featureless images (all black, all sky) can share a hash; make sure they match.
                if FeaturePrint.distance(first.candidate.analysis.featurePrint, a.featurePrint) <= options.maxFeatureDistance / 3 {
                    parent[root(index)] = root(first.cluster)
                }
            }
        }

        var merged: [Int: [Candidate]] = [:]
        for (index, cluster) in clusters.enumerated() { merged[root(index), default: []] += cluster }
        return Array(merged.values)
    }

    private static func worstDistance(_ cluster: [Candidate], _ candidate: Candidate) -> Float {
        cluster.map { FeaturePrint.distance($0.analysis.featurePrint, candidate.analysis.featurePrint) }.max() ?? 0
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
