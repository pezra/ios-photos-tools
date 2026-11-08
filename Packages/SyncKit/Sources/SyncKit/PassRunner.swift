import Foundation

/// Runs one pass at a time. Starting while a pass is going joins it instead of making another.
///
/// Each engine has a runner of its own. A coordinator that runs several parts together can keep one
/// runner per part and cancel them separately.
public final class PassRunner: @unchecked Sendable {
    private struct Current {
        let id: UInt64
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var current: Current?
    private var nextID: UInt64 = 0

    public init() {}

    public var isRunning: Bool {
        lock.withLock { current != nil }
    }

    /// Starts `body` unless a pass is going, in which case that pass is returned and `body` is dropped.
    ///
    /// `onEnd` runs on every exit path, after `body` returns and before the next pass may start,
    /// with whether the pass was cancelled. It must not wait for this runner's pass.
    @discardableResult
    public func start(onEnd: (@Sendable (_ cancelled: Bool) async -> Void)? = nil,
                      _ body: @escaping @Sendable () async -> Void) -> (task: Task<Void, Never>, isNew: Bool) {
        lock.withLock {
            if let current { return (current.task, false) }
            let id = nextID
            nextID += 1
            let task = Task {
                await body()
                await onEnd?(Task.isCancelled)
                lock.withLock { if current?.id == id { current = nil } }
            }
            current = Current(id: id, task: task)
            return (task, true)
        }
    }

    /// Waits for the pass in progress, if there is one. Cancelling the caller doesn't stop the pass.
    public func join() async {
        let task = lock.withLock { current?.task }
        await task?.value
    }

    /// Starts a pass (or joins the one in progress) and waits for it. Cancelling the caller
    /// cancels the pass, whether this caller started it or joined it.
    public func run(onEnd: (@Sendable (_ cancelled: Bool) async -> Void)? = nil,
                    _ body: @escaping @Sendable () async -> Void) async {
        await withTaskCancellationHandler {
            await start(onEnd: onEnd, body).task.value
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        lock.withLock { current?.task }?.cancel()
    }

    /// Cancels the pass and waits until it has ended. Returns whether there was one.
    @discardableResult
    public func cancelAndWait() async -> Bool {
        var wasRunning = false
        while let task = lock.withLock({ current?.task }) {
            wasRunning = true
            task.cancel()
            await task.value
        }
        return wasRunning
    }
}
