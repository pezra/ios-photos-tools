import Foundation
import SyncKit

extension BackupStore {
    /// The drive folder is forgotten if the layout changes, so the new layout doesn't go into the
    /// old folder: the user chooses the library's folder.
    static let shared: BackupStore = {
        BackupStore(path: AppDirectories.support.appendingPathComponent("backup.sqlite").path) { DriveDestination.forget() }
    }()
}
