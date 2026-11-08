import CryptoKit
import Foundation

/// Holds exported copies of photos while the background session uploads them.
///
/// Background uploads must come from a file that stays put until the transfer finishes,
/// so this lives in Application Support (not Caches, which the system may purge).
enum Staging {
    static let directory: URL = {
        var url = AppDirectories.support
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

    /// `progress` is told how far through the file the hashing has got, from 0 to 1.
    static func sha256(of file: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        Log.hash.info("Hashing \(file.lastPathComponent, privacy: .public)")
        let signpost = Log.signposter.beginInterval("hash", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("hash", signpost) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = progress == nil ? 0 : Double(file.fileSize ?? 0)
        var hasher = SHA256()
        var read = 0.0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            read += Double(chunk.count)
            if size > 0 { progress?(min(read / size, 1)) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// How much is staged.
    static func size() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Free space on the disk staged files go to, if it can be found.
    static func availableBytes() -> Int64? {
        try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    /// Deletes staged files that no upload refers to any more.
    static func removeOrphans(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !names.contains(file) {
            remove(file)
        }
    }
}
