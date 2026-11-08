import Foundation

/// What a run does: which parts, what each part needs listed first, and whether a listing is made
/// again or the last run's is used. Decided from plain values; `BackupRun` in the app gathers them.
public enum RunPlan {
    public enum Part: String, CaseIterable, Hashable, Sendable {
        /// Staging photos for the bucket.
        case bucket
        /// Copying photos to the drive.
        case drive
        /// Syncing low-res copies to the phone.
        case sync
    }

    public enum Trigger: Equatable, Sendable {
        /// The app coming to the foreground, or settings being closed. Throttled.
        case opened
        /// The background processing task, or photo access just granted. Not throttled.
        case automatic
        /// A tap on a row's button, or the drive being plugged in: those parts, then the sync.
        case user(Set<Part>)
        /// The uploads settled with photos left to stage.
        case uploadsSettled
    }

    /// What's set up and switched on.
    public struct Setup: Equatable, Sendable {
        public var bucket: Bool
        public var autoBackup: Bool
        /// A drive folder has been chosen, whether or not the drive is plugged in.
        public var drive: Bool
        public var driveAutoBackup: Bool
        public var sync: Bool

        public init(bucket: Bool, autoBackup: Bool, drive: Bool, driveAutoBackup: Bool, sync: Bool) {
            self.bucket = bucket
            self.autoBackup = autoBackup
            self.drive = drive
            self.driveAutoBackup = driveAutoBackup
            self.sync = sync
        }

        /// What runs without being asked for.
        var automaticParts: Set<Part> {
            var parts: Set<Part> = []
            if bucket && autoBackup { parts.insert(.bucket) }
            if drive && driveAutoBackup { parts.insert(.drive) }
            if sync { parts.insert(.sync) }
            return parts
        }

        func allows(_ part: Part) -> Bool {
            switch part {
            case .bucket: bucket
            case .drive: drive
            case .sync: sync
            }
        }
    }

    /// The one rule for repeated runs: the app being opened doesn't start a run within this long of
    /// the last one finishing, and a run that a tap starts within it uses the last run's listings.
    public static let throttle: TimeInterval = 5 * 60

    /// The parts a new run started by `trigger` does, or nil when it shouldn't start: an opening
    /// within `throttle` of the last run finishing, unless `setupChanged` (a destination, or what's
    /// switched on, is different from the last run's).
    public static func parts(for trigger: Trigger, setup: Setup, lastRunEnded: Date?, setupChanged: Bool,
                             now: Date) -> Set<Part>? {
        switch trigger {
        case .opened:
            if let lastRunEnded, now.timeIntervalSince(lastRunEnded) < throttle, !setupChanged { return nil }
            return setup.automaticParts
        case .automatic:
            return setup.automaticParts
        case .user(let asked):
            return asked.union([.sync]).filter(setup.allows)
        case .uploadsSettled:
            return Set([Part.bucket].filter(setup.allows))
        }
    }

    /// The parts `trigger` adds to a run that's already going. Opening the app or the background
    /// task joins it as it is, so they don't restart a part the user paused.
    public static func joining(_ trigger: Trigger, setup: Setup) -> Set<Part> {
        switch trigger {
        case .opened, .automatic: []
        case .user(let asked): asked.filter(setup.allows)
        case .uploadsSettled: Set([Part.bucket].filter(setup.allows))
        }
    }

    /// Whether the app being opened (or returned to) with the drive attached asks for a continued
    /// task, which the user has said counts as plugging the drive in. Only when there's something to
    /// copy. The library hasn't been listed yet at that point, so `uncopied` is an estimate: the
    /// library's photos, less the low-res copies left out of it, less what the drive has.
    public static func requestsTaskWhenOpened(setup: Setup, driveReachable: Bool, uncopied: Int) -> Bool {
        setup.drive && setup.driveAutoBackup && driveReachable && uncopied > 0
    }

    /// The listings a part needs before it starts. `pending` is how many photos it has to do, and
    /// `parts` what the run does.
    ///
    /// Names are checked against both places, so copying to the drive needs the bucket's listing
    /// too (made once per run, by whichever part gets there first). Staging goes by the bucket's
    /// alone, as it always has, but waits for a drive listing being made in the same run.
    public static func needs(_ part: Part, pending: Int, parts: Set<Part>, setup: Setup) -> (drive: Bool, bucket: Bool) {
        switch part {
        case .bucket:
            return (false, setup.bucket && pending > 0)
        case .drive:
            return (setup.drive && (pending > 0 || parts.contains(.sync)), setup.bucket && pending > 0)
        case .sync:
            return (setup.drive, setup.bucket)
        }
    }

    public enum Listing: Equatable, Sendable {
        case list
        /// The listing kept from the last run will do.
        case reuse
    }

    /// Whether a place is listed again. A listing that the last run made is used by a run that
    /// starts within `throttle` of that one finishing, which only a tap or settling uploads can do.
    /// A bucket that can't refuse an upload to a taken name has only its listing to go by, so it's
    /// always listed, and so is a place that has just changed.
    public static func listing(listedAt: Date?, lastRun: ClosedRange<Date>?, now: Date, changed: Bool,
                               refusesTakenNames: Bool = true) -> Listing {
        guard refusesTakenNames, !changed, let listedAt, let lastRun,
              listedAt >= lastRun.lowerBound, now.timeIntervalSince(lastRun.upperBound) < throttle
        else { return .list }
        return .reuse
    }
}
