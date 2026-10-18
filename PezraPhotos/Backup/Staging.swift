import Foundation

/// Holds exported copies of photos while the background session uploads them.
///
/// Background uploads must come from a file that stays put until the transfer finishes,
/// so this lives in Application Support (not Caches, which the system may purge).
enum Staging {
    static let directory: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    /// Staged files are referenced by name only; the app container path can change between launches.
    static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    static func remove(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Deletes staged files that no upload refers to any more.
    static func removeOrphans(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !names.contains(file) {
            remove(file)
        }
    }
}
