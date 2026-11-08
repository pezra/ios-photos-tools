import Foundation
import os

/// What the app is doing, for Console.app or `log stream`, filtered by subsystem and category. Paths
/// and counts are logged publicly, since they're what the checks look for. No credentials are logged.
enum Log {
    static let subsystem = "org.barelyenough.ios-photos-tools"

    static let listing = Logger(subsystem: subsystem, category: "listing")
    static let export = Logger(subsystem: subsystem, category: "export")
    static let hash = Logger(subsystem: subsystem, category: "hash")
    static let handledPaths = Logger(subsystem: subsystem, category: "handled-paths")
    static let pass = Logger(subsystem: subsystem, category: "pass")
    static let upload = Logger(subsystem: subsystem, category: "upload")
    static let continuedTask = Logger(subsystem: subsystem, category: "continued-task")
    static let background = Logger(subsystem: subsystem, category: "background")

    /// Intervals for Instruments' os_signpost track.
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// Runs `body` as a signposted interval named `name`.
    static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}

extension Logger {
    /// A pass's phase changes: its start and end at info level, the steps between at debug level.
    func log(phase: String, of pass: String, running: Bool, startingPass: Bool) {
        if startingPass {
            info("\(pass, privacy: .public) pass started")
        }
        if running {
            debug("\(pass, privacy: .public): \(phase, privacy: .public)")
        } else {
            info("\(pass, privacy: .public) pass ended: \(phase, privacy: .public)")
        }
    }
}
