import BackgroundTasks

/// Schedules backup passes whenever iOS lets the app run in the background (on battery or charging).
enum BackgroundTasks {
    static let backupTaskID = "org.barelyenough.ios-photos-tools.backup"

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backupTaskID, using: nil) { task in
            handle(task as! BGProcessingTask)
        }
    }

    static func schedule() {
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
        task.expirationHandler = { BackupEngine.stop() }
        Task {
            await BackupEngine.shared.run()
            task.setTaskCompleted(success: true)
        }
    }
}
