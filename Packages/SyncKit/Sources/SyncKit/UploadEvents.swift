import Foundation

/// Tells any number of listeners that something changed. It doesn't say what: listeners read the
/// store for that, after subscribing and after every wake-up, so a missed or stale signal can't
/// leave one waiting for something that has already happened.
public final class ChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Waits still going, and those of them woken before they were added to `waiting`.
    private var active: Set<Int> = []
    private var wokenEarly: Set<Int> = []

    public init() {}

    /// How many signals have been sent. Read it before reading the store, and pass it to `wait`.
    public var current: Int { lock.withLock { generation } }

    public func send() {
        let woken = lock.withLock {
            generation += 1
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        woken.forEach { $0.resume() }
    }

    /// Returns once a signal has been sent since `current` was `seen` (straight away if one already
    /// has), or when `timeout` passes, or the task is cancelled. Returns whether a signal was sent.
    @discardableResult
    public func wait(since seen: Int, timeout: Duration) async -> Bool {
        let id = lock.withLock {
            nextID += 1
            active.insert(nextID)
            return nextID
        }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.wake(id)
        }
        defer {
            timer.cancel()
            lock.withLock {
                active.remove(id)
                wokenEarly.remove(id)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock {
                    if generation != seen || wokenEarly.contains(id) || Task.isCancelled { return true }
                    waiting[id] = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        } onCancel: {
            wake(id)
        }
        return current != seen
    }

    /// Waits until `condition` holds, checking it now and after every signal. Returns whether it
    /// does, once it does, or once `stallLimit` passes with no signal or the task is cancelled.
    public func wait(until condition: () -> Bool, stallLimit: Duration) async -> Bool {
        while !Task.isCancelled {
            let seen = current
            if condition() { return true }
            guard await wait(since: seen, timeout: stallLimit) else { return condition() }
        }
        return condition()
    }

    private func wake(_ id: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let continuation = waiting.removeValue(forKey: id) { return continuation }
            if active.contains(id) { wokenEarly.insert(id) }
            return nil
        }
        continuation?.resume()
    }
}

/// Notices uploads settling: the number in flight reaching zero. The number is read from the store
/// every time, so signals only say when to look again.
public final class SettleTracker: @unchecked Sendable {
    private let signal: ChangeSignal
    private let uploading: @Sendable () -> Int
    private let lock = NSLock()
    /// Whether uploads have been seen in flight since the last settle. True to begin with, so
    /// uploads that finished before anyone was listening still settle once.
    private var unsettled = true

    /// `uploading` reads how many uploads are in flight.
    public init(signal: ChangeSignal, uploading: @escaping @Sendable () -> Int) {
        self.signal = signal
        self.uploading = uploading
    }

    /// Reads the count. Returns true if this is the uploads settling: none in flight, with some
    /// seen since the last settle.
    public func check() -> Bool {
        let count = uploading()
        return lock.withLock {
            if count > 0 {
                unsettled = true
                return false
            }
            defer { unsettled = false }
            return unsettled
        }
    }

    /// Waits for the next settle. Checks now, after every signal, and every `recheckEvery` in case
    /// a signal went missing. Returns false if the task is cancelled first.
    public func nextSettle(recheckEvery interval: Duration = .seconds(60)) async -> Bool {
        while !Task.isCancelled {
            let seen = signal.current
            if check() { return true }
            await signal.wait(since: seen, timeout: interval)
        }
        return false
    }
}

/// How much a pass may stage for upload before it has to wait or stop.
public enum StagingBudget {
    public enum Room: Equatable, Sendable {
        case room
        /// In the foreground: wait for an upload to finish.
        case waitForSlot
        /// In the background: stop staging, and leave the rest for another run.
        case full
    }

    /// Uploads in flight at once in the foreground, which bounds disk use while they finish quickly.
    public static let foregroundSlots = 8
    /// Uploads started in the background are discretionary and iOS paces them, so waiting for slots
    /// there could take hours. Up to this much is staged instead.
    public static let backgroundBytes: Int64 = 2 << 30
    /// Disk space left free whatever the budget.
    public static let reserveBytes: Int64 = 1 << 30

    /// `stagedBytes` is what's staged now, and `availableBytes` the free space, if known.
    public static func room(background: Bool, uploading: Int, stagedBytes: Int64, availableBytes: Int64?) -> Room {
        if background {
            let hasSpace = availableBytes.map { $0 > reserveBytes } ?? true
            return stagedBytes < backgroundBytes && hasSpace ? .room : .full
        }
        return uploading < foregroundSlots ? .room : .waitForSlot
    }
}
