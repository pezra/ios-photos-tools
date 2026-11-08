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
        submit(backupTaskID, needsNetwork: true, label: "background backup")
    }

    private static func submit(_ identifier: String, needsNetwork: Bool, label: String) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = needsNetwork
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.background.info("Scheduled \(label, privacy: .public)")
        } catch {
            Log.background.error("Couldn't schedule \(label, privacy: .public): \(error, privacy: .public)")
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        Log.background.info("Background backup started")
        schedule()
        task.expirationHandler = {
            Log.background.info("Background backup expired")
            BackupEngine.stop()
            DriveBackupEngine.stop()
            LibrarySyncEngine.stop()
        }
        Task {
            async let drive: Void = SettingsStore.driveAutoBackup && DriveDestination.isConnected
                ? DriveBackupEngine.shared.run() : ()
            await BackupEngine.shared.run()
            await drive
            await LibrarySyncEngine.shared.run()
            task.setTaskCompleted(success: true)
            Log.background.info("Background backup completed")
        }
    }

    private static func scheduleTrips() {
        guard SettingsStore.tripAlbums else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: tripsTaskID)
            return
        }
        submit(tripsTaskID, needsNetwork: false, label: "trip albums")
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
