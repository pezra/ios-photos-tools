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
    var coverage = BackupStore.Coverage()
    var uploading = 0
    var failed = 0
    var lastError: String?
    var lastFinished: Date? {
        didSet { UserDefaults.standard.set(lastFinished, forKey: "lastFinished") }
    }
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    private init() {
        lastFinished = UserDefaults.standard.object(forKey: "lastFinished") as? Date
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let authorized = PhotoLibrary.isAuthorized
        // Listing a large library takes a moment, so it's done off the main thread.
        Task.detached(priority: .utility) {
            var ids: [String] = []
            if authorized {
                PhotoLibrary.fetchAllAssets().enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
            }
            BackupStore.shared.setLibraryAssets(ids)
            await BackupStatus.shared.refreshCounts()
        }
        refreshCounts()
    }

    func refreshCounts() {
        let store = BackupStore.shared
        coverage = store.coverage(driveID: DriveDestination.id)
        uploading = store.count(.uploading)
        failed = store.count(.failed)
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
