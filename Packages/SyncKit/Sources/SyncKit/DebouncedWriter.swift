import Foundation

/// Writes the latest value it was given, off the calling thread, some time after the first of a
/// run of changes, so a burst of changes is one write. `flush()` writes whatever is waiting
/// straight away, for when the app is about to be suspended.
public final class DebouncedWriter<Value: Sendable>: @unchecked Sendable {
    private let delay: TimeInterval
    private let write: @Sendable (Value) -> Void
    /// Writes happen here, one at a time.
    private let queue = DispatchQueue(label: "DebouncedWriter", qos: .utility)
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled: DispatchWorkItem?

    public init(delay: TimeInterval, write: @escaping @Sendable (Value) -> Void) {
        self.delay = delay
        self.write = write
    }

    /// Replaces any value still waiting. A write follows within `delay` of the first change after
    /// the last write.
    public func submit(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        guard scheduled == nil else { return }
        let item = DispatchWorkItem { [self] in drain() }
        scheduled = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes what's waiting and returns once it's written. Don't call from the main thread.
    public func flush() {
        queue.sync { drain() }
    }

    private func drain() {
        lock.lock()
        let value = pending
        pending = nil
        scheduled?.cancel()
        scheduled = nil
        lock.unlock()
        if let value { write(value) }
    }
}
