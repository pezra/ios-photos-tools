import Foundation
import Observation
import Photos

/// What the UI shows about backup progress.
@MainActor
@Observable
final class BackupStatus {
    static let shared = BackupStatus()

    var isRunning = false
    var phase = "Idle"
    var totalAssets = 0
    var completedAssets = 0
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
        totalAssets = PhotoLibrary.isAuthorized ? PhotoLibrary.fetchAllAssets().count : 0
        refreshCounts()
    }

    func refreshCounts() {
        let store = BackupStore.shared
        completedAssets = store.completedAssetCount()
        uploading = store.count(.uploading)
        failed = store.count(.failed)
    }
}
