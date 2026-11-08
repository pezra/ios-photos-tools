import Foundation

/// How far a run has got, summed over its steps. Each step has a fixed share of the whole, so a step
/// learning its size never makes the total go backwards, and each step reports in its own units.
/// A step's fraction and the total only ever go up.
///
/// iOS ends a continued task whose progress stops moving, and some work (a big video, a download
/// from iCloud) gives no signal for a while. `nudge` moves the steps that have started along a
/// little, but never more than `nudgeCap` past what has really been done.
public struct RunProgress: Sendable, Equatable {
    public enum Kind: Hashable, Sendable {
        /// Reading the drive or listing the bucket.
        case listing
        /// Copying, staging or importing.
        case work
    }

    public struct Step: Hashable, Sendable {
        public let part: RunPlan.Part
        public let kind: Kind

        public init(_ part: RunPlan.Part, _ kind: Kind) {
            self.part = part
            self.kind = kind
        }
    }

    /// Each part gets 100 units: a fifth for listing, the rest for the work.
    public static func share(of step: Step) -> Int64 {
        step.kind == .listing ? 20 : 80
    }

    /// How far a nudge moves a step, and how far past the real progress nudges can take it.
    public static let nudgeAmount = 0.002
    public static let nudgeCap = 0.03
    /// A step whose size isn't known yet is shown as `done / (done + this)`, which only goes up.
    public static let unknownTotalScale = 5000.0
    /// Where a step with no known size stops until it finishes.
    private static let unknownTotalCeiling = 0.9
    private static let nudgeCeiling = 0.99

    private struct State: Equatable {
        var real = 0.0
        var shown = 0.0
        var started = false
        var finished = false
    }

    private var steps: [Step: State] = [:]
    private var peak = 0.0

    public init(parts: Set<RunPlan.Part> = []) {
        parts.forEach { add($0) }
    }

    /// Makes room for a part. Does nothing if it's there already.
    public mutating func add(_ part: RunPlan.Part) {
        for kind in [Kind.listing, .work] where steps[Step(part, kind)] == nil {
            steps[Step(part, kind)] = State()
        }
    }

    public var parts: Set<RunPlan.Part> { Set(steps.keys.map(\.part)) }

    /// The steps in a run's tree, with their shares.
    public var shares: [(step: Step, share: Int64)] {
        let order = RunPlan.Part.allCases
        let sorted = steps.keys.sorted { a, b in
            let (i, j) = (order.firstIndex(of: a.part) ?? 0, order.firstIndex(of: b.part) ?? 0)
            return i != j ? i < j : a.kind == .listing && b.kind == .work
        }
        return sorted.map { (step: $0, share: Self.share(of: $0)) }
    }

    /// `step` has done `completed` of `total` of its own units. A total that isn't known yet is nil.
    public mutating func update(_ step: Step, completed: Double, of total: Double?) {
        guard var state = steps[step], !state.finished else { return }
        let fraction: Double
        if let total {
            fraction = total > 0 ? min(max(completed / total, 0), 1) : 1
        } else {
            let done = max(completed, 0)
            fraction = Self.unknownTotalCeiling * done / (done + Self.unknownTotalScale)
        }
        state.started = true
        state.real = max(state.real, fraction)
        state.shown = max(state.shown, state.real)
        steps[step] = state
        recomputePeak()
    }

    public mutating func update(_ step: Step, completed: Int, of total: Int?) {
        update(step, completed: Double(completed), of: total.map(Double.init))
    }

    public mutating func finish(_ step: Step) {
        guard var state = steps[step] else { return }
        state = State(real: 1, shown: 1, started: true, finished: true)
        steps[step] = state
        recomputePeak()
    }

    /// Finishes everything a part does, as when it ends early or is paused.
    public mutating func finish(_ part: RunPlan.Part) {
        finish(Step(part, .listing))
        finish(Step(part, .work))
    }

    /// For steps that have started and not finished: a little more than they've shown, up to
    /// `nudgeCap` past what has really been done.
    public mutating func nudge() {
        for (step, var state) in steps where state.started && !state.finished {
            let limit = min(state.real + Self.nudgeCap, Self.nudgeCeiling)
            state.shown = max(state.shown, min(state.shown + Self.nudgeAmount, limit))
            steps[step] = state
        }
        recomputePeak()
    }

    /// One step's fraction.
    public func fraction(of step: Step) -> Double {
        steps[step]?.shown ?? 0
    }

    /// The whole run's fraction, which never goes down, even when a part is added.
    public var fraction: Double { peak }

    private mutating func recomputePeak() {
        var weighted = 0.0
        var total = 0.0
        for (step, state) in steps {
            let share = Double(Self.share(of: step))
            weighted += share * state.shown
            total += share
        }
        guard total > 0 else { return }
        peak = max(peak, weighted / total)
    }
}

/// How far one file's transfer has got, when it's downloaded from iCloud first and then written.
/// The download is the first half, if there is one.
public struct TransferProgress: Sendable, Equatable {
    /// The file's size, if it's known without reading it.
    public let size: Int64?
    private var downloaded: Double?
    private var written: Int64 = 0
    private var shown = 0.0

    public init(size: Int64?) {
        self.size = size
    }

    /// The share of the download done, from 0 to 1.
    public mutating func download(_ fraction: Double) {
        downloaded = max(downloaded ?? 0, min(max(fraction, 0), 1))
    }

    /// Bytes written so far in all.
    public mutating func wrote(_ bytes: Int64) {
        written = max(written, bytes)
    }

    /// Never goes down. With no size and no download, nothing is known until it's done.
    public mutating func fraction() -> Double {
        let writing = size.map { $0 > 0 ? min(Double(written) / Double($0), 1) : 1 }
        let value: Double
        switch (downloaded, writing) {
        case let (download?, writing?): value = 0.5 * download + 0.5 * writing
        case let (download?, nil): value = 0.5 * download
        case let (nil, writing?): value = writing
        case (nil, nil): value = 0
        }
        shown = max(shown, value)
        return shown
    }
}
