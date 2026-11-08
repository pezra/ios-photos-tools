import Foundation

/// Watches for the backup drive while the app is open and starts a backup when it appears.
///
/// iOS has no notification for USB drives being attached (and won't launch an app for one), so
/// this polls the drive's bookmark. A drive already there when the app first opens is the opening
/// run's to copy to; one that's appeared since the app was last open counts as plugged in.
@MainActor
final class DriveMonitor {
    static let shared = DriveMonitor()

    private let interval: Duration = .seconds(3)
    private var polling: Task<Void, Never>?
    /// Whether the drive was there when last looked at, kept while the app is in the background.
    /// Nil until the first look.
    private var wasConnected: Bool?

    func start() {
        guard polling == nil else { return }
        polling = Task {
            while !Task.isCancelled {
                // A pass in progress has the drive open, and notices itself if it goes away.
                if DriveStatus.shared.isRunning {
                    wasConnected = true
                    try? await Task.sleep(for: interval)
                    continue
                }
                let isConnected = await Task.detached { DriveDestination.isConnected }.value
                DriveStatus.shared.isConnected = isConnected
                if isConnected && wasConnected == false && SettingsStore.driveAutoBackup {
                    BackupRun.drivePlugged()
                }
                wasConnected = isConnected
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }
}
