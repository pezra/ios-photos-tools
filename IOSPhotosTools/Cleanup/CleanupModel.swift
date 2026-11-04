import Observation
import Photos
import UIKit

/// Finds groups of near-duplicate photos and deletes the ones the user doesn't want to keep.
@MainActor
@Observable
final class CleanupModel {
    static let shared = CleanupModel()

    enum Scope: Hashable {
        /// Photos taken since the last finished scan, or in the last 30 days if there hasn't been one.
        case recent
        case wholeLibrary
    }

    /// How far back a recent scan looks when there's no earlier scan to start from.
    private static let defaultLookback: TimeInterval = 30 * 24 * 60 * 60

    private(set) var isScanning = false
    private(set) var phase = "Not scanned yet"
    private(set) var analyzedCount = 0
    private(set) var totalCount = 0
    private(set) var groups: [DuplicateGroup] = []
    private(set) var lastError: String?
    /// Photos to delete: everything but the best of each group, less any the user has kept.
    private(set) var marked: Set<String> = []
    /// 0 (only near-identical) to 1 (loosely similar).
    var looseness: Double = 0.5 {
        didSet { regroup() }
    }
    var scope = Scope.recent
    /// When the last scan that ran to completion started.
    private(set) var lastScanStarted: Date? {
        didSet { UserDefaults.standard.set(lastScanStarted, forKey: "lastCleanupScanStarted") }
    }

    private var scan: Task<Void, Never>?
    private var candidates: [Candidate] = []
    /// Near duplicates the user unmarked. They stay unmarked in every later scan.
    private var kept = AnalysisStore.shared.keptIDs()

    private init() {
        lastScanStarted = UserDefaults.standard.object(forKey: "lastCleanupScanStarted") as? Date
    }

    /// Earliest capture date a recent scan looks at.
    var recentCutoff: Date {
        lastScanStarted ?? Date(timeIntervalSinceNow: -Self.defaultLookback)
    }

    var markedCount: Int { marked.count }

    func start() {
        guard scan == nil else { return }
        scan = Task {
            await performScan()
            scan = nil
        }
    }

    func stop() {
        scan?.cancel()
    }

    func toggle(_ assetID: String) {
        let keep = marked.contains(assetID)
        if keep { marked.remove(assetID) } else { marked.insert(assetID) }
        if keep { kept.insert(assetID) } else { kept.remove(assetID) }
        AnalysisStore.shared.setKept(assetID, keep)
    }

    /// Asks Photos to delete the marked photos. Photos shows its own confirmation and keeps them
    /// in Recently Deleted for 30 days.
    func deleteMarked() async {
        let ids = Array(marked)
        guard !ids.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return
        } catch {
            lastError = error.localizedDescription
            return
        }

        let deleted = Set(ids)
        AnalysisStore.shared.remove(ids)
        candidates.removeAll { deleted.contains($0.id) }
        regroup()
        BackupStatus.shared.refresh()
    }

    // MARK: - Scanning

    private func performScan() async {
        guard PhotoLibrary.isAuthorized else {
            phase = "Photo access needed"
            return
        }
        isScanning = true
        lastError = nil
        phase = "Checking library…"
        // Analysis takes a while for big libraries; don't let the phone lock and suspend us.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isScanning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let started = Date()
        let library = Self.fetchPhotos()
        var cached = AnalysisStore.shared.all()
        let libraryIDs = Set(library.map(\.localIdentifier))
        AnalysisStore.shared.remove(Array(Set(cached.keys).union(kept).subtracting(libraryIDs)))
        kept.formIntersection(libraryIDs)
        cached = cached.filter { libraryIDs.contains($0.key) }

        let assets: [PHAsset]
        switch scope {
        case .wholeLibrary:
            assets = library
        case .recent:
            // Reach back one grouping window so shots straddling the cutoff still get compared.
            let since = recentCutoff.addingTimeInterval(-DuplicateGrouper.Options().window)
            assets = library.filter { ($0.creationDate ?? .distantPast) >= since }
        }

        let pending = assets.filter {
            LibraryAnalyzer.needsAnalysis($0, cached: cached[$0.localIdentifier])
        }
        totalCount = assets.count
        analyzedCount = assets.count - pending.count

        var analyses = cached
        var failures = 0
        await LibraryAnalyzer.analyze(pending) { id, result in
            switch result {
            case .success(let analysis):
                analyses[id] = analysis
            case .failure(let error):
                failures += 1
                lastError = error.localizedDescription
            }
            analyzedCount += 1
            phase = "Analyzing \(analyzedCount) of \(totalCount)"
        }

        candidates = assets.compactMap { asset in
            analyses[asset.localIdentifier].map {
                Candidate(analysis: $0, createdAt: asset.creationDate, isFavorite: asset.isFavorite,
                          isEdited: asset.hasAdjustments, burstID: asset.burstIdentifier)
            }
        }
        regroup()

        if Task.isCancelled {
            phase = "Paused — \(totalCount - analyzedCount) photos left to analyze"
        } else if failures > 0 {
            lastScanStarted = started
            phase = "Done (\(failures) photos couldn't be analyzed)"
        } else {
            lastScanStarted = started
            phase = "Done"
        }
    }

    private func regroup() {
        var options = DuplicateGrouper.Options()
        options.maxFeatureDistance = Float(0.25 + 0.4 * looseness)
        // Groups where the user has already kept every alternative have nothing left to decide.
        groups = DuplicateGrouper.groups(candidates, options: options)
            .filter { group in group.assetIDs.dropFirst().contains { !kept.contains($0) } }
        marked = Set(groups.flatMap { $0.assetIDs.dropFirst() }).subtracting(kept)
    }

    /// Visible still photos, including every shot of each burst. Hidden photos are left alone.
    private static func fetchPhotos() -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }
}
