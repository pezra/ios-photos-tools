import Foundation

/// Watches for the backup drive while the app is open and starts a backup when it appears.
///
/// iOS has no notification for USB drives being attached (and won't launch an app for one), so
/// this polls the drive's bookmark.
@MainActor
final class DriveMonitor {
    static let shared = DriveMonitor()

    private let interval: Duration = .seconds(3)
    private var polling: Task<Void, Never>?

    func start() {
        guard polling == nil else { return }
        polling = Task {
            // Starts out false so a drive that's already plugged in is backed up when the app opens.
            var wasConnected = false
            while !Task.isCancelled {
                let isConnected = await Task.detached { DriveDestination.isConnected }.value
                DriveStatus.shared.isConnected = isConnected
                if isConnected && !wasConnected && SettingsStore.driveAutoBackup {
                    DriveBackupEngine.start()
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
