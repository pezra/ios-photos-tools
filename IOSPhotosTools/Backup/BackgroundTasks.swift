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
        // A background run is an activation of its own, and the next foreground one lists again.
        LibrarySnapshot.invalidate()
        schedule()
        task.expirationHandler = {
            Log.background.info("Background backup expired")
            BackupRun.stopAll(because: "the background task expired")
        }
        Task {
            await BackupRun.shared.run(.automatic, because: "background task")
            LibrarySnapshot.invalidate()
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
        LibrarySnapshot.invalidate()
        task.expirationHandler = {
            Task { @MainActor in TripsModel.shared.stop() }
        }
        Task { @MainActor in
            await TripsModel.shared.syncNow()
            LibrarySnapshot.invalidate()
            task.setTaskCompleted(success: true)
        }
    }
}
