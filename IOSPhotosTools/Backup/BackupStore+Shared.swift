import Foundation
import SyncKit

extension BackupStore {
    /// The drive folder is forgotten if the layout changes, so the new layout doesn't go into the
    /// old folder: the user chooses the library's folder.
    static let shared: BackupStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return BackupStore(path: dir.appendingPathComponent("backup.sqlite").path) { DriveDestination.forget() }
    }()
}
