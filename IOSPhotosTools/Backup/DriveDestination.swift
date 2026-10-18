import Foundation

/// The folder on a USB drive that photos are copied to.
///
/// The app keeps access to it through a security-scoped bookmark, which only resolves while the
/// drive is plugged in. iOS doesn't tell apps when a drive is attached, so `DriveMonitor` checks
/// the bookmark periodically while the app is open.
enum DriveDestination {
    private enum Key {
        static let bookmark = "driveBookmark"
        static let name = "driveName"
        static let id = "driveID"
    }

    private static let defaults = UserDefaults.standard

    /// Changes whenever a different folder is chosen, so copy history is kept per folder.
    static var id: String? { defaults.string(forKey: Key.id) }
    static var name: String? { defaults.string(forKey: Key.name) }

    /// Remembers `folder` (as returned by the document picker) as the backup destination.
    static func configure(folder: URL) throws {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let volume = (try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        let name = if let volume, volume != folder.lastPathComponent { "\(volume) › \(folder.lastPathComponent)" } else { folder.lastPathComponent }

        defaults.set(bookmark, forKey: Key.bookmark)
        defaults.set(name, forKey: Key.name)
        defaults.set(UUID().uuidString, forKey: Key.id)
    }

    static func forget() {
        for key in [Key.bookmark, Key.name, Key.id] { defaults.removeObject(forKey: key) }
    }

    /// Resolves the folder and starts security-scoped access to it, or returns nil when the drive
    /// isn't connected. Balance with `close`.
    static func open() -> URL? {
        guard let bookmark = defaults.data(forKey: Key.bookmark) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        guard (try? url.checkResourceIsReachable()) == true else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        if isStale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Key.bookmark)
        }
        return url
    }

    static func close(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    static var isConnected: Bool {
        guard let url = open() else { return false }
        close(url)
        return true
    }
}

