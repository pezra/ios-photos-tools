import Foundation
import Observation
import Photos
import SyncKit

/// What the UI shows about cloud backup progress, and how much of the library is backed up where.
@MainActor
@Observable
final class BackupStatus {
    static let shared = BackupStatus()
    /// The phase of a pass that ended with uploads still going. The row shows how many from the counts.
    nonisolated static let waitingForUploads = "Waiting for uploads"

    private var pass = PassStatus(lastFinishedKey: "lastFinished")
    var isRunning: Bool { pass.isRunning }
    var phase: String { pass.phase }
    var lastError: String? { pass.lastError }
    var lastFinished: Date? { pass.lastFinished }
    /// Saved so the last counts show at launch while the library is being listed.
    var coverage: BackupStore.Coverage {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(coverage), forKey: "coverage") }
    }
    var uploading = 0
    var failed = 0
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private var listingLibrary = false
    private var coverageRefreshScheduled = false
    private var countsInFlight = false
    private var countsRerun = false

    private init() {
        coverage = UserDefaults.standard.data(forKey: "coverage")
            .flatMap { try? JSONDecoder().decode(BackupStore.Coverage.self, from: $0) } ?? BackupStore.Coverage()
    }

    /// Lists the library again (e.g. after photos were added or deleted) and refreshes the counts.
    /// `relist: false` keeps the library as listed for this activation.
    func refresh(relist: Bool = true) {
        if relist { LibrarySnapshot.invalidate() }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        refreshCounts()
        guard !listingLibrary else { return }
        listingLibrary = true
        // Listing a large library takes a moment, so it's done off the main thread.
        Task.detached(priority: .utility) {
            _ = await LibrarySnapshot.current()
            await MainActor.run {
                let status = BackupStatus.shared
                status.listingLibrary = false
                status.refreshCounts()
            }
        }
    }

    func report(phase: String, running: Bool, error: String?, finished: Bool, startingPass: Bool) {
        pass.report(phase: phase, running: running, error: error, finished: finished, startingPass: startingPass)
        refreshCounts()
    }

    /// The store's lock is held through long transactions, and this is called for every file backed
    /// up, so the counts are read off the main thread. One read runs at a time; calls while it runs
    /// share one more read afterwards. Results apply here one after another, so an old one can't
    /// land after a newer one.
    func refreshCounts() {
        guard !countsInFlight else { countsRerun = true; return }
        countsInFlight = true
        Task {
            repeat {
                countsRerun = false
                let counts = await Task.detached(priority: .utility) {
                    let store = BackupStore.shared
                    let failed = store.count(.failed)
                    return (uploading: store.count(.uploading), failed: failed,
                            lastError: failed > 0 ? store.lastError() : nil)
                }.value
                apply(counts)
            } while countsRerun
            countsInFlight = false
        }
    }

    private func apply(_ counts: (uploading: Int, failed: Int, lastError: String?)) {
        uploading = counts.uploading
        failed = counts.failed
        // A pass that ended with uploads going shows how they went once they've finished.
        if !pass.isRunning && pass.phase == Self.waitingForUploads && uploading == 0 {
            pass.report(phase: failed > 0 ? "Finished with \(failed) failed files" : "Up to date", running: false,
                        error: failed > 0 ? counts.lastError : nil, finished: true)
        }
        scheduleCoverageRefresh()
    }

    /// The coverage query goes over the whole library and this is called for every file backed
    /// up, so it runs off the main thread, at most about once a second.
    private func scheduleCoverageRefresh() {
        guard !coverageRefreshScheduled else { return }
        coverageRefreshScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            coverageRefreshScheduled = false
            let driveID = DriveDestination.id
            if let coverage = await Task.detached(priority: .utility, operation: { BackupStore.shared.coverage(driveID: driveID) }).value {
                self.coverage = coverage
            }
        }
    }
}

/// What the UI shows about syncing low-res copies to the phone.
@MainActor
@Observable
final class SyncStatus {
    static let shared = SyncStatus()

    private var pass = PassStatus(lastFinishedKey: "syncLastFinished")
    var isRunning: Bool { pass.isRunning }
    var phase: String { pass.phase }
    var lastError: String? { pass.lastError }
    var lastFinished: Date? { pass.lastFinished }
    var remaining = 0
    var failed = 0

    private init() {}

    func report(phase: String, running: Bool, error: String?, finished: Bool, startingPass: Bool) {
        pass.report(phase: phase, running: running, error: error, finished: finished, startingPass: startingPass)
    }
}

/// What the UI shows about copying to the USB drive.
@MainActor
@Observable
final class DriveStatus {
    static let shared = DriveStatus()

    var isConnected = false
    private var pass = PassStatus(lastFinishedKey: "driveLastFinished")
    var isRunning: Bool { pass.isRunning }
    var phase: String { pass.phase }
    var lastError: String? { pass.lastError }
    var lastFinished: Date? { pass.lastFinished }

    private init() {}

    func report(phase: String, running: Bool, error: String?, finished: Bool, startingPass: Bool) {
        pass.report(phase: phase, running: running, error: error, finished: finished, startingPass: startingPass)
    }
}
