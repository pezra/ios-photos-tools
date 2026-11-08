import Foundation

/// Writes the handled paths file to one place, one write at a time. Two writes at once could land
/// out of order, leaving the older content there while the newer version was recorded as written.
public actor HandledPathsWriter {
    private let store: BackupStore
    /// The meta key recording the version last written here.
    private let key: String
    private var last: Task<Void, Never>?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var writers: [String: HandledPathsWriter] = [:]

    public init(store: BackupStore, key: String) {
        self.store = store
        self.key = key
    }

    /// The one writer for the place whose version is recorded under `key`.
    public static func shared(store: BackupStore, key: String) -> HandledPathsWriter {
        lock.withLock {
            if let writer = writers[key] { return writer }
            let writer = HandledPathsWriter(store: store, key: key)
            writers[key] = writer
            return writer
        }
    }

    /// Writes the file with `put` if it's out of date: by any change if `force`, otherwise by at
    /// least `interval` changes. Waits for any write already going first. Returns the version
    /// written, or nil if none was due.
    public func write(force: Bool, interval: Int, put: @escaping @Sendable (Data) async throws -> Void) async throws -> Int? {
        let previous = last
        let task = Task {
            await previous?.value
            return try await perform(force: force, interval: interval, put: put)
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    private func perform(force: Bool, interval: Int, put: @Sendable (Data) async throws -> Void) async throws -> Int? {
        let written = Int(store.meta(key) ?? "") ?? -1
        let current = store.handledVersion
        guard force ? written != current : current - written >= interval else { return nil }
        // The version recorded is the one these entries were read at.
        let (version, entries) = store.handledSnapshot()
        try await put(HandledPathsFile.encode(entries))
        store.setMeta(key, String(version))
        return version
    }
}
