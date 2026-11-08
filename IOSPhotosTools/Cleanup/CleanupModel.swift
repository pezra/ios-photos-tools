import Observation
import Photos
import TripKit
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
    private var candidates: [DuplicateCandidate] = []
    private var regrouping: Task<Void, Never>?
    /// Photos the user marked (true) or unmarked while groups were being found.
    private var tapsSinceRegroup: [String: Bool] = [:]
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
        if regrouping != nil { tapsSinceRegroup[assetID] = !keep }
        if keep {
            marked.remove(assetID)
            kept.insert(assetID)
        } else {
            marked.insert(assetID)
            kept.remove(assetID)
        }
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
        await Task.detached { AnalysisStore.shared.remove(ids) }.value
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
        let scope = scope
        // Reach back one grouping window so shots straddling the cutoff still get compared.
        let since = recentCutoff.addingTimeInterval(-DuplicateGrouper.Options().window)
        let kept = kept
        let plan = await Task.detached(priority: .userInitiated) {
            await Self.plan(scope: scope, since: since, kept: kept)
        }.value
        // Taps made during the scan changed `kept` meanwhile, so only drop what left the library.
        self.kept.formIntersection(plan.libraryIDs)
        let assets = plan.assets
        totalCount = assets.count
        analyzedCount = assets.count - plan.pending.count
        Log.library.info("Cleanup: \(assets.count) photos in scope, \(plan.cached.count) analyses loaded, \(plan.pending.count) to analyze, planned in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")

        var analyses = plan.cached
        var failures = 0
        await LibraryAnalyzer.analyze(plan.pending) { id, result in
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

        phase = "Grouping…"
        let all = analyses
        candidates = await Task.detached(priority: .userInitiated) {
            assets.compactMap { asset in
                all[asset.localIdentifier].map { DuplicateCandidate(analysis: $0, asset: asset) }
            }
        }.value
        let grouping = Date()
        await regroup().value
        Log.library.info("Cleanup: \(self.candidates.count) candidates grouped into \(self.groups.count) groups in \(Date().timeIntervalSince(grouping), format: .fixed(precision: 2)) s")

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

    /// What a scan works on, found off the main thread.
    private struct ScanPlan: @unchecked Sendable {
        let assets: [PHAsset]
        let cached: [String: PhotoAnalysis]
        let pending: [PHAsset]
        let libraryIDs: Set<String>
    }

    /// Lists the library, forgets what's no longer in it, and loads the cached analyses of the
    /// photos in scope (not the whole cache for a recent scan).
    private nonisolated static func plan(scope: Scope, since: Date, kept: Set<String>) async -> ScanPlan {
        let library = await LibrarySnapshot.current().burstShots()
        let store = AnalysisStore.shared
        let libraryIDs = Set(library.map(\.localIdentifier))
        store.remove(Array(store.analysisIDs().union(kept).subtracting(libraryIDs)))

        var assets: [PHAsset]
        let cached: [String: PhotoAnalysis]
        switch scope {
        case .wholeLibrary:
            assets = library
            cached = store.all().filter { libraryIDs.contains($0.key) }
        case .recent:
            assets = library.filter { ($0.creationDate ?? .distantPast) >= since }
            cached = store.analyses(assets.map(\.localIdentifier))
        }
        #if DEBUG
        if let limit = TestHooks.cleanupLimit { assets = Array(assets.prefix(limit)) }
        #endif
        let pending = assets.filter {
            LibraryAnalyzer.needsAnalysis($0, cached: cached[$0.localIdentifier])
        }
        return ScanPlan(assets: assets, cached: cached, pending: pending, libraryIDs: libraryIDs)
    }

    /// Groups the candidates off the main thread. A newer call replaces one still running, and
    /// taps made meanwhile are applied to whatever comes back.
    @discardableResult
    private func regroup() -> Task<Void, Never> {
        regrouping?.cancel()
        var options = DuplicateGrouper.Options()
        options.maxFeatureDistance = Float(0.25 + 0.4 * looseness)
        let candidates = candidates
        let kept = kept
        let task = Task {
            let work = Task.detached(priority: .userInitiated) {
                // Groups where the user has already kept every alternative have nothing left to decide.
                DuplicateGrouper.groups(candidates, options: options)
                    .filter { group in group.assetIDs.dropFirst().contains { !kept.contains($0) } }
            }
            // A newer slider position stops this one's work instead of queueing behind it.
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            var marked = Set(found.flatMap { $0.assetIDs.dropFirst() }).subtracting(kept)
            for (id, mark) in tapsSinceRegroup {
                if mark { marked.insert(id) } else { marked.remove(id) }
            }
            groups = found
            self.marked = marked
            tapsSinceRegroup = [:]
            regrouping = nil
        }
        regrouping = task
        return task
    }
}
