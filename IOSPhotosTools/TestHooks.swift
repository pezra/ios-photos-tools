#if DEBUG
import Foundation

/// Lets the simulator scripts in `scripts/sim` set the app up without tapping through settings.
/// Debug builds only. Read from the environment at launch, which `xcrun simctl launch` passes on
/// from `SIMCTL_CHILD_`-prefixed variables:
///
/// - `PT_TEST_SETTINGS`: JSON with any of `endpoint`, `region`, `bucket`, `prefix`, `accessKeyID`,
///   `secretAccessKey`, `usePathStyle`, `autoBackup`, `driveAutoBackup`, `tripAlbums`, `syncEnabled`.
///   Saved as if typed into settings.
/// - `PT_TEST_DRIVE`: the name of a folder in the app's Documents to use as the drive, created if
///   needed. Standing in for a folder chosen on a USB drive.
/// - `PT_TEST_FORGET_AFTER`: a number of photos. Once the bucket pass has registered that many,
///   "Forget backup history" is tapped, while the last of them is still being staged.
enum TestHooks {
    private struct Settings: Decodable {
        var endpoint: String?
        var region: String?
        var bucket: String?
        var prefix: String?
        var accessKeyID: String?
        var secretAccessKey: String?
        var usePathStyle: Bool?
        var autoBackup: Bool?
        var driveAutoBackup: Bool?
        var tripAlbums: Bool?
        var syncEnabled: Bool?
    }

    private static let forgetAfter = ProcessInfo.processInfo.environment["PT_TEST_FORGET_AFTER"].flatMap(Int.init)
    private static let staged = NSLock()
    nonisolated(unsafe) private static var stagedCount = 0

    /// Called by the bucket pass each time it registers a photo's files.
    static func photoRegistered() {
        guard let forgetAfter else { return }
        let count = staged.withLock {
            stagedCount += 1
            return stagedCount
        }
        guard count == forgetAfter else { return }
        Log.background.info("Test hook: forgetting backup history after \(count) photos")
        Task { await BackupEngine.shared.forgetHistory() }
    }

    /// Must run before the app's `SettingsStore` is made, so it reads what's saved here.
    static func apply() {
        let environment = ProcessInfo.processInfo.environment
        if let json = environment["PT_TEST_SETTINGS"] {
            applySettings(json)
        }
        if let name = environment["PT_TEST_DRIVE"] {
            applyDrive(name)
        }
    }

    private static func applySettings(_ json: String) {
        guard let given = try? JSONDecoder().decode(Settings.self, from: Data(json.utf8)) else {
            return Log.background.error("PT_TEST_SETTINGS isn't valid JSON")
        }
        let store = SettingsStore()
        if let v = given.endpoint { store.endpoint = v }
        if let v = given.region { store.region = v }
        if let v = given.bucket { store.bucket = v }
        if let v = given.prefix { store.prefix = v }
        if let v = given.accessKeyID { store.accessKeyID = v }
        if let v = given.secretAccessKey { store.secretAccessKey = v }
        if let v = given.usePathStyle { store.usePathStyle = v }
        if let v = given.autoBackup { store.autoBackup = v }
        if let v = given.driveAutoBackup { store.driveAutoBackup = v }
        if let v = given.tripAlbums { store.tripAlbums = v }
        if let v = given.syncEnabled { store.syncEnabled = v }
        Log.background.info("Test settings applied")
    }

    private static func applyDrive(_ name: String) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try SettingsStore().setDrive(folder: folder)
            Log.background.info("Test drive set to Documents/\(name, privacy: .public)")
        } catch {
            Log.background.error("Couldn't set the test drive: \(error, privacy: .public)")
        }
    }
}
#endif
