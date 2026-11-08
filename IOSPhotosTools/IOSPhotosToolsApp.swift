import SwiftUI

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
                // A backup pass ends by syncing, so that new backups count as dealt with first.
                if settings.autoBackup { BackupEngine.start() } else { LibrarySyncEngine.start() }
                if settings.tripAlbums { TripsModel.shared.start() }
                DriveMonitor.shared.start()
            case .background:
                wasInBackground = true
                DriveMonitor.shared.stop()
                BackgroundTasks.schedule()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundTasks.register()
        // Reconnect to the background upload session so completions that happened while we were
        // suspended get delivered.
        UploadSession.shared.activate()
        BackupEngine.watchUploads()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == UploadSession.identifier else { return completionHandler() }
        Log.background.info("Woken for upload events")
        // Called as soon as the events are handled, which records them in the store and nothing
        // more: no network writes, since iOS gives this little time.
        UploadSession.shared.backgroundCompletionHandler = completionHandler
        UploadSession.shared.activate()
    }
}
