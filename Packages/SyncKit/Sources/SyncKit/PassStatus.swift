import Foundation

/// What a pass shows the user: whether it's running, what it's doing, how the last one ended and
/// when. Held by each `@Observable` status class, which `@Observable` can't share by subclassing.
public struct PassStatus: Sendable {
    public var isRunning = false
    public var phase = "Idle"
    public private(set) var lastError: String?
    public private(set) var lastFinished: Date?

    private let key: String
    private let defaults: UserDefaults

    /// `lastFinishedKey` is where the time of the last finished pass is kept, so it shows at launch.
    public init(lastFinishedKey: String, defaults: UserDefaults = .standard) {
        key = lastFinishedKey
        self.defaults = defaults
        lastFinished = defaults.object(forKey: lastFinishedKey) as? Date
    }

    /// The one rule for errors: a pass starting clears the previous pass's, which otherwise lingers
    /// when that pass was paused; one that finished replaces it with its own, or none; one that's
    /// still going only adds to it.
    public mutating func report(phase: String, running: Bool, error: String? = nil, finished: Bool = false,
                                startingPass: Bool = false, at date: Date = Date()) {
        self.phase = phase
        isRunning = running
        if startingPass {
            lastError = nil
        } else if finished {
            lastFinished = date
            defaults.set(date, forKey: key)
            lastError = error
        } else if let error {
            lastError = error
        }
    }
}
