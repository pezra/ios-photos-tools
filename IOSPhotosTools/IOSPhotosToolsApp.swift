import SwiftUI
import SyncKit

@main
struct IOSPhotosToolsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = BackupStatus.shared
    @State private var settings: SettingsStore
    @State private var drive = DriveStatus.shared
    @State private var sync = SyncStatus.shared
    /// Set when the app goes to the background, so that coming back lists the library again.
    @State private var wasInBackground = false

    init() {
        #if DEBUG
        TestHooks.apply()
        #endif
        _settings = State(initialValue: SettingsStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(status)
                .environment(settings)
                .environment(drive)
                .environment(sync)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // A new launch has nothing listed yet. Coming back from the background lists the library
                // again, once for everything that starts now.
                status.refresh(relist: wasInBackground)
                wasInBackground = false
                BackupRun.start(.opened, because: "app opened")
                BackupRun.opened()
                if settings.tripAlbums { TripsModel.shared.start() }
                DriveMonitor.shared.start()
            case .background:
                wasInBackground = true
                DriveMonitor.shared.stop()
                BackgroundTasks.schedule()
                flushTripStore()
            default:
                break
            }
        }
    }

    /// Writes trip changes still waiting for their delay, before the app is suspended.
    private func flushTripStore() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Save trips") {
            UIApplication.shared.endBackgroundTask(task)
        }
        Task.detached {
            TripStore.flush()
            await UIApplication.shared.endBackgroundTask(task)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundTasks.register()
        connectUploads()
        // Launched in the background before the phone was first unlocked, the database can't be
        // opened until it is.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.connectUploads()
        }
        return true
    }

    private var uploadsConnected = false

    /// Reconnects to the background upload session so completions that happened while we were
    /// suspended get delivered, once the store they're recorded in can be opened.
    private func connectUploads() {
        guard !uploadsConnected else { return }
        guard BackupStore.open() != nil else {
            return Log.background.error("Upload events left for later: the backup database can't be opened")
        }
        uploadsConnected = true
        UploadSession.shared.activate()
        BackupEngine.watchUploads()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == UploadSession.identifier else { return completionHandler() }
        Log.background.info("Woken for upload events")
        guard BackupStore.open() != nil else {
            // They're delivered when the session is next connected.
            Log.background.error("Upload events left for later: the backup database can't be opened")
            return completionHandler()
        }
        // Called as soon as the events are handled, which records them in the store and nothing
        // more: no network writes, since iOS gives this little time.
        UploadSession.shared.backgroundCompletionHandler = completionHandler
        connectUploads()
    }
}
