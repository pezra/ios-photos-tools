import Foundation

/// Lets the parts of a run that work side by side start together: each prepares what it needs,
/// then waits until every part expected has prepared too, or has ended (paused, or nothing to do).
/// A part that joins once the others are working doesn't hold them up.
public final class PartBarrier<Part: Hashable & Sendable>: @unchecked Sendable {
    private enum State { case preparing, ready, ended }

    private let lock = NSLock()
    private var states: [Part: State] = [:]
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    public init() {}

    /// The parts about to start, before any of them does, so one that's quick to prepare waits for
    /// those that haven't begun.
    public func expect(_ parts: some Sequence<Part>) {
        lock.withLock { for part in parts { states[part] = .preparing } }
    }

    /// Waits until no expected part is still preparing. Returns early if the caller is cancelled.
    public func ready(_ part: Part) async {
        let id: UInt64 = lock.withLock {
            states[part] = .ready
            nextID += 1
            return nextID
        }
        release()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiting: Bool = lock.withLock {
                    guard isPreparing, !Task.isCancelled else { return false }
                    waiters[id] = continuation
                    return true
                }
                if !waiting { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume()
        }
    }

    public func ended(_ part: Part) {
        lock.withLock { states[part] = .ended }
        release()
    }

    private var isPreparing: Bool {
        states.values.contains(.preparing)
    }

    private func release() {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !isPreparing else { return [] }
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        released.forEach { $0.resume() }
    }
}

/// Does each job once: the first caller does it and later ones are done at once. Callers that arrive
/// while it's being done wait for it, and if it fails (or its caller is cancelled), the next one
/// tries again. Used for preparing each place once per run.
public final class OnceEach<Key: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Set<Key> = []
    private var doing: Set<Key> = []
    private var waiters: [Key: [UInt64: CheckedContinuation<Void, Never>]] = [:]
    private var nextID: UInt64 = 0
    private enum Step { case finished, wait(UInt64), work }

    public init() {}

    public func isDone(_ key: Key) -> Bool {
        lock.withLock { done.contains(key) }
    }

    /// Returns once it's done. Throws what `job` threw, if this caller did it and it failed.
    public func run(_ key: Key, _ job: () async throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            let step: Step = lock.withLock {
                if done.contains(key) { return .finished }
                if doing.contains(key) {
                    nextID += 1
                    return .wait(nextID)
                }
                doing.insert(key)
                return .work
            }
            switch step {
            case .finished:
                return
            case .wait(let id):
                await wait(for: key, id: id)
            case .work:
                do {
                    try await job()
                    finish(key, succeeded: true)
                    return
                } catch {
                    finish(key, succeeded: false)
                    throw error
                }
            }
        }
    }

    private func wait(for key: Key, id: UInt64) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let waiting: Bool = lock.withLock {
                    guard doing.contains(key), !Task.isCancelled else { return false }
                    waiters[key, default: [:]][id] = continuation
                    return true
                }
                if !waiting { continuation.resume() }
            }
        } onCancel: {
            lock.withLock { waiters[key]?.removeValue(forKey: id) }?.resume()
        }
    }

    private func finish(_ key: Key, succeeded: Bool) {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            doing.remove(key)
            if succeeded { done.insert(key) }
            return waiters.removeValue(forKey: key).map { Array($0.values) } ?? []
        }
        released.forEach { $0.resume() }
    }
}

/// Keeps work on the same key from overlapping, as the bucket and the drive do for each photo:
/// the second to ask waits for the first to finish.
public final class KeyedLock: @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func withLock<T>(_ key: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(key)
        defer { release(key) }
        return try await body()
    }

    private func acquire(_ key: String) async {
        await withCheckedContinuation { continuation in
            let free: Bool = lock.withLock {
                guard queues[key] != nil else {
                    queues[key] = []
                    return true
                }
                queues[key]?.append(continuation)
                return false
            }
            if free { continuation.resume() }
        }
    }

    private func release(_ key: String) {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard var queue = queues[key], !queue.isEmpty else {
                queues[key] = nil
                return nil
            }
            let next = queue.removeFirst()
            queues[key] = queue
            return next
        }
        next?.resume()
    }
}
