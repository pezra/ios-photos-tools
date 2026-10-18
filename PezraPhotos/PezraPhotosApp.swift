import SwiftUI

@main
struct PezraPhotosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = BackupStatus.shared
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(status)
                .environment(settings)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                status.refresh()
                if settings.autoBackup { BackupEngine.start() }
            case .background:
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
