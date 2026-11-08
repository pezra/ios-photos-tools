#if DEBUG
import CoreImage
import Foundation
import Photos
import SyncKit

/// Lets the simulator scripts in `scripts/sim` set the app up without tapping through settings.
/// Debug builds only. Read from the environment at launch, which `xcrun simctl launch` passes on
/// from `SIMCTL_CHILD_`-prefixed variables:
///
/// - `PT_TEST_SETTINGS`: JSON with any of `endpoint`, `region`, `bucket`, `prefix`, `accessKeyID`,
///   `secretAccessKey`, `usePathStyle`, `autoBackup`, `driveAutoBackup`, `tripAlbums`, `syncEnabled`.
///   Saved as if typed into settings.
/// - `PT_TEST_DRIVE`: the name of a folder in the app's Documents to use as the drive, created if
///   needed. Standing in for a folder chosen on a USB drive.
/// - `PT_TEST_EDIT`: a number of photos to edit (colours inverted), the newest first. Edited again
///   each time, so each launch gives them new edited versions.
/// - `PT_TEST_FORGET_AFTER`: a number of photos. Once the bucket pass has registered that many,
///   "Forget backup history" is tapped, while the last of them is still being staged.
/// - `PT_TEST_PAUSE`: `row,after,resume` where row is `bucket`, `drive` or `sync`, and both times are
///   seconds. Taps that row's pause button `after` seconds after launch and its start button
///   `resume` seconds later. Several can be given, separated by semicolons.
/// - `PT_TEST_TAP`: `row,after`. Taps that row's start button `after` seconds after launch.
///   Several can be given, separated by semicolons.
/// - `PT_TEST_PAUSE_DRIVE_IN_SYNC`: any value. Pauses the drive when the sync pass first starts,
///   which leaves the sync running.
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

    nonisolated(unsafe) private static var pausedInSync = false

    /// Called when the sync pass starts.
    static func syncStarted() {
        guard ProcessInfo.processInfo.environment["PT_TEST_PAUSE_DRIVE_IN_SYNC"] != nil, !pausedInSync else { return }
        pausedInSync = true
        Log.background.info("Test hook: pausing drive during its sync step")
        BackupRun.pause(.drive)
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
        if let spec = environment["PT_TEST_PAUSE"] {
            for part in spec.split(separator: ";") { pauseAndResume(String(part)) }
        }
        if let spec = environment["PT_TEST_TAP"] {
            for part in spec.split(separator: ";") { tap(String(part)) }
        }
        if let count = environment["PT_TEST_EDIT"].flatMap(Int.init) {
            Task.detached { await editPhotos(count) }
        }
    }

    private static func pauseAndResume(_ spec: String) {
        let parts = spec.split(separator: ",").map(String.init)
        guard parts.count == 3, let after = Double(parts[1]), let resume = Double(parts[2]) else {
            return Log.background.error("PT_TEST_PAUSE isn't row,after,resume")
        }
        guard let row = RunPlan.Part(rawValue: parts[0]) else {
            return Log.background.error("PT_TEST_PAUSE row isn't bucket, drive or sync")
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(after))
            Log.background.info("Test hook: pausing \(row.rawValue, privacy: .public)")
            BackupRun.pause(row)
            try? await Task.sleep(for: .seconds(resume))
            Log.background.info("Test hook: resuming \(row.rawValue, privacy: .public)")
            await BackupRun.tap(row)
        }
    }

    private static func tap(_ spec: String) {
        let parts = spec.split(separator: ",").map(String.init)
        guard parts.count == 2, let row = RunPlan.Part(rawValue: parts[0]), let after = Double(parts[1]) else {
            return Log.background.error("PT_TEST_TAP isn't row,after")
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(after))
            Log.background.info("Test hook: tapping \(row.rawValue, privacy: .public)")
            await BackupRun.tap(row)
        }
    }

    private static func editPhotos(_ count: Int) async {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = count
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            do {
                try await edit(asset)
                Log.background.info("Test hook: edited \(asset.localIdentifier, privacy: .public)")
            } catch {
                Log.background.error("Test hook: couldn't edit \(asset.localIdentifier, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private static func edit(_ asset: PHAsset) async throws {
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.canHandleAdjustmentData = { _ in false }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input { continuation.resume(returning: input) } else {
                    continuation.resume(throwing: info[PHContentEditingInputErrorKey] as? Error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        guard let url = input.fullSizeImageURL, let image = CIImage(contentsOf: url) else { throw CocoaError(.fileReadUnknown) }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "org.barelyenough.ios-photos-tools.test",
                                                 formatVersion: "1", data: Data(UUID().uuidString.utf8))
        try CIContext().writeJPEGRepresentation(of: image.applyingFilter("CIColorInvert"), to: output.renderedContentURL,
                                                colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
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
