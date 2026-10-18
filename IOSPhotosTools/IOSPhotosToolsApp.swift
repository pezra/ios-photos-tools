import SwiftUI

@main
struct IOSPhotosToolsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = BackupStatus.shared
    @State private var settings = SettingsStore()
    @State private var drive = DriveStatus.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(status)
                .environment(settings)
                .environment(drive)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                status.refresh()
                if settings.autoBackup { BackupEngine.start() }
                DriveMonitor.shared.start()
            case .background:
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
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == UploadSession.identifier else { return completionHandler() }
        UploadSession.shared.backgroundCompletionHandler = completionHandler
        UploadSession.shared.activate()
    }
}
