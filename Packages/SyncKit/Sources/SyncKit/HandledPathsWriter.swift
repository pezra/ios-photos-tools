import Foundation

/// Writes the handled paths file to one place, one write at a time. Two writes at once could land
/// out of order, leaving the older content there while the newer version was recorded as written.
public actor HandledPathsWriter {
    private let store: BackupStore
    /// The meta key recording the version last written here.
    private let key: String
    private let now: @Sendable () -> Date
    private var timeKey: String { key + "-at" }
    private var last: Task<Void, Never>?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var writers: [String: HandledPathsWriter] = [:]

    /// How long to leave the file alone after a write, unless a pass is ending.
    public static let minimumGap: TimeInterval = 5 * 60

    /// `now` is the clock, replaceable so tests can move time.
    public init(store: BackupStore, key: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.key = key
        self.now = now
    }

    /// Whether a write is due: something changed since the last one, and either the pass is
    /// ending (`force`) or `gap` has passed since it. With no write yet recorded, a change is due.
    public static func isDue(force: Bool, changed: Bool, sinceLastWrite: TimeInterval?, gap: TimeInterval = minimumGap) -> Bool {
        guard changed else { return false }
        if force { return true }
        guard let sinceLastWrite else { return true }
        return sinceLastWrite >= gap
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

    /// Writes the file with `put` if something changed and it's due: always when `force`,
    /// otherwise once `gap` has passed since the last write here. Waits for any write already
    /// going first. Returns the version written, or nil if none was due.
    public func write(force: Bool, gap: TimeInterval = HandledPathsWriter.minimumGap, put: @escaping @Sendable (Data) async throws -> Void) async throws -> Int? {
        let previous = last
        let task = Task {
            await previous?.value
            return try await perform(force: force, gap: gap, put: put)
        }
        last = Task { _ = try? await task.value }
        return try await task.value
    }

    private func perform(force: Bool, gap: TimeInterval, put: @Sendable (Data) async throws -> Void) async throws -> Int? {
        let written = Int(store.meta(key) ?? "") ?? -1
        let writtenAt = Double(store.meta(timeKey) ?? "").map { Date(timeIntervalSince1970: $0) }
        guard Self.isDue(force: force, changed: written != store.handledVersion, sinceLastWrite: writtenAt.map { now().timeIntervalSince($0) }, gap: gap) else { return nil }
        // The version recorded is the one these entries were read at.
        let (version, entries) = store.handledSnapshot()
        try await put(HandledPathsFile.encode(entries))
        store.setMeta(key, String(version))
        store.setMeta(timeKey, String(now().timeIntervalSince1970))
        return version
    }
}
