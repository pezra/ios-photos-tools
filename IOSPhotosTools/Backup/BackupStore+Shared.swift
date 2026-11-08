import Foundation
import os
import SyncKit

extension BackupStore {
    private static let opened = OSAllocatedUnfairLock<BackupStore?>(initialState: nil)

    /// The store, or nil while its database can't be opened, as before the phone's first unlock after
    /// a restart. Tried again each time until it opens. Work that can start in the background checks
    /// this first and is skipped when it's nil.
    ///
    /// The drive folder is forgotten if the layout changes, so the new layout doesn't go into the
    /// old folder: the user chooses the library's folder.
    static func open() -> BackupStore? {
        opened.withLock { store in
            if let store { return store }
            do {
                store = try BackupStore(path: AppDirectories.support.appendingPathComponent("backup.sqlite").path) { DriveDestination.forget() }
            } catch {
                Log.background.error("\(error.localizedDescription, privacy: .public)")
            }
            return store
        }
    }

    /// For code that only runs once `open()` has given a store: in the foreground, or after checking.
    static var shared: BackupStore {
        guard let store = open() else { preconditionFailure("The backup database isn't open: check BackupStore.open() first") }
        return store
    }
}
