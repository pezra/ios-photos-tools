import BackgroundTasks

/// Schedules backup passes whenever iOS lets the app run in the background (on battery or charging).
/// If the USB drive happens to be plugged in then, it's backed up too. Trip albums are kept up to
/// date the same way.
enum BackgroundTasks {
    static let backupTaskID = "org.barelyenough.ios-photos-tools.backup"
    static let tripsTaskID = "org.barelyenough.ios-photos-tools.trips"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupTaskID, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: tripsTaskID, using: nil) { task in
            handleTrips(task as! BGProcessingTask)
        }
    }

    static func schedule() {
        scheduleTrips()
        guard let settings = SettingsStore.snapshot(), settings.autoBackup else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backupTaskID)
            return
        }
        let request = BGProcessingTaskRequest(identifier: backupTaskID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Couldn't schedule background backup: \(error)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        schedule()
        task.expirationHandler = {
            BackupEngine.stop()
            DriveBackupEngine.stop()
        }
        Task {
            async let drive: Void = SettingsStore.driveAutoBackup && DriveDestination.isConnected
                ? DriveBackupEngine.shared.run() : ()
            await BackupEngine.shared.run()
            await drive
            task.setTaskCompleted(success: true)
        }
    }

    private static func scheduleTrips() {
        guard SettingsStore.tripAlbums else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: tripsTaskID)
            return
        }
        let request = BGProcessingTaskRequest(identifier: tripsTaskID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Couldn't schedule trip albums: \(error)")
        }
    }

    private static func handleTrips(_ task: BGProcessingTask) {
        scheduleTrips()
        task.expirationHandler = {
            Task { @MainActor in TripsModel.shared.stop() }
        }
        Task { @MainActor in
            await TripsModel.shared.syncNow()
            task.setTaskCompleted(success: true)
        }
    }
}
