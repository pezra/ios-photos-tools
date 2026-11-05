import Foundation
import Observation
import Photos

/// What the UI shows about cloud backup progress, and how much of the library is backed up where.
@MainActor
@Observable
final class BackupStatus {
    static let shared = BackupStatus()

    var isRunning = false
    var phase = "Idle"
    /// Saved so the last counts show at launch while the library is being listed.
    var coverage: BackupStore.Coverage {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(coverage), forKey: "coverage") }
    }
    var uploading = 0
    var failed = 0
    var lastError: String?
    var lastFinished: Date? {
        didSet { UserDefaults.standard.set(lastFinished, forKey: "lastFinished") }
    }
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private var listingLibrary = false
    private var coverageRefreshScheduled = false

    private init() {
        lastFinished = UserDefaults.standard.object(forKey: "lastFinished") as? Date
        coverage = UserDefaults.standard.data(forKey: "coverage")
            .flatMap { try? JSONDecoder().decode(BackupStore.Coverage.self, from: $0) } ?? BackupStore.Coverage()
    }

    /// Re-lists the library (e.g. after photos were added or deleted) and refreshes the counts.
    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        refreshCounts()
        guard !listingLibrary else { return }
        listingLibrary = true
        let authorized = PhotoLibrary.isAuthorized
        // Listing a large library takes a moment, so it's done off the main thread.
        Task.detached(priority: .utility) {
            var ids: [String] = []
            if authorized {
                PhotoLibrary.enumerateOwnAssets(PhotoLibrary.fetchAllAssets()) { ids.append($0.localIdentifier) }
            }
            BackupStore.shared.setLibraryAssets(ids)
            await MainActor.run {
                let status = BackupStatus.shared
                status.listingLibrary = false
                status.refreshCounts()
            }
        }
    }

    func refreshCounts() {
        let store = BackupStore.shared
        uploading = store.count(.uploading)
        failed = store.count(.failed)
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

    var isRunning = false
    var phase = "Idle"
    var remaining = 0
    var failed = 0
    var lastError: String?
    var lastFinished: Date? {
        didSet { UserDefaults.standard.set(lastFinished, forKey: "syncLastFinished") }
    }

    private init() {
        lastFinished = UserDefaults.standard.object(forKey: "syncLastFinished") as? Date
    }
}

/// What the UI shows about copying to the USB drive.
@MainActor
@Observable
final class DriveStatus {
    static let shared = DriveStatus()

    var isConnected = false
    var isRunning = false
    var phase = "Idle"
    var lastError: String?
    var lastFinished: Date? {
        didSet { UserDefaults.standard.set(lastFinished, forKey: "driveLastFinished") }
    }

    private init() {
        lastFinished = UserDefaults.standard.object(forKey: "driveLastFinished") as? Date
    }
}
