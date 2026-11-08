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
/// - `PT_TEST_WATCHDOG`: any value. A timer on the main thread logs each time it fires more than
///   100 ms late, and a total every 10 seconds, as a stand-in for Instruments' hangs report (which
///   the simulator can't record). Category `background`, messages starting "Watchdog".
/// - `PT_TEST_CLEANUP`: actions on the Duplicates screen, each `name@seconds` after launch, separated
///   by semicolons: `open`, `scan`, `scope:recent` or `scope:whole`, and `slider:0.8` (released at that
///   position), `limit:N` (scan only the newest N photos), and `seed:N`, which saves made-up analyses for the newest N photos (the simulator can't
///   run Vision), in runs of three that look alike. For example `scope:whole@2;open@3;scan@5;slider:0.9@30`. Logged in category `background`.
/// - `PT_TEST_TRIPS_SAVE`: seconds. That long after launch, asks for the trips file to be saved
///   (with what it holds), to see a save wait out its delay or be flushed when the app is backgrounded.
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
        if environment["PT_TEST_WATCHDOG"] != nil {
            watchMainThread()
        }
        if let spec = environment["PT_TEST_PAUSE"] {
            for part in spec.split(separator: ";") { pauseAndResume(String(part)) }
        }
        if let spec = environment["PT_TEST_TAP"] {
            for part in spec.split(separator: ";") { tap(String(part)) }
        }
        if let after = environment["PT_TEST_TRIPS_SAVE"].flatMap(Double.init) {
            Task.detached {
                try? await Task.sleep(for: .seconds(after))
                Log.background.info("Test hook: saving trips")
                TripStore.save(TripStore.load())
            }
        }
        if let spec = environment["PT_TEST_CLEANUP"] {
            for part in spec.split(separator: ";") { cleanup(String(part)) }
        }
        if let count = environment["PT_TEST_EDIT"].flatMap(Int.init) {
            Task.detached { await editPhotos(count) }
        }
    }

    /// How many photos a Duplicates scan looks at, if `limit:N` was given.
    nonisolated(unsafe) static var cleanupLimit: Int?

    /// Posted to have the home screen open Duplicates.
    static let openCleanup = Notification.Name("PTOpenCleanup")

    private static func cleanup(_ spec: String) {
        let parts = spec.split(separator: "@").map(String.init)
        guard parts.count == 2, let after = Double(parts[1]) else {
            return Log.background.error("PT_TEST_CLEANUP action isn't name@seconds")
        }
        let action = parts[0]
        if action.hasPrefix("seed:"), let count = Int(action.dropFirst(5)) {
            Task.detached {
                try? await Task.sleep(for: .seconds(after))
                await seedAnalyses(count)
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            Log.background.info("Test hook: cleanup \(action, privacy: .public)")
            let model = CleanupModel.shared
            switch action.split(separator: ":").map(String.init) {
            case ["open"]: NotificationCenter.default.post(name: openCleanup, object: nil)
            case ["scan"]: model.start()
            case let parts where parts.count == 2 && parts[0] == "limit" && Int(parts[1]) != nil:
                cleanupLimit = Int(parts[1])
            case ["scope", "recent"]: model.scope = .recent
            case ["scope", "whole"]: model.scope = .wholeLibrary
            case let parts where parts.count == 2 && parts[0] == "slider" && Double(parts[1]) != nil:
                model.looseness = Double(parts[1])!
            default: Log.background.error("PT_TEST_CLEANUP doesn't know \(action, privacy: .public)")
            }
        }
    }

    private static func seedAnalyses(_ count: Int) async {
        let assets = await LibrarySnapshot.current().burstShots().prefix(count)
        var state: UInt64 = 42
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
        var scene: [Float] = []
        var sceneHash: UInt64 = 0
        for (index, asset) in assets.enumerated() {
            if index % 3 == 0 {
                scene = (0..<768).map { _ in next() }
                sceneHash = UInt64(bitPattern: Int64(truncatingIfNeeded: state))
            }
            var print = scene.map { $0 + 0.01 * next() }
            let length = print.reduce(0) { $0 + $1 * $1 }.squareRoot()
            print = print.map { $0 / length }
            AnalysisStore.shared.save(PhotoAnalysis(
                assetID: asset.localIdentifier, modifiedAt: asset.modificationDate?.timeIntervalSince1970,
                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                dHash: sceneHash ^ UInt64(index % 3), featurePrint: print, aesthetics: Float(index % 7) / 10,
                isUtility: false, faceQuality: nil, faceCount: 0, faceArea: 0, personArea: 0,
                sharpness: Double(10 + index % 5), version: PhotoAnalyzer.version))
        }
        Log.background.info("Test hook: seeded \(assets.count) analyses")
    }

    private static func watchMainThread() {
        Task { @MainActor in
            let start = ContinuousClock.now
            var last = start
            var hangs = 0
            var worst = 0.0
            var total = 0.0
            var reported = start
            while true {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                let late = (now - last - .milliseconds(10)) / .milliseconds(1)
                last = now
                if late > 100 {
                    hangs += 1
                    worst = max(worst, late)
                    total += late
                    Log.background.info("Watchdog: main thread late by \(Int(late)) ms")
                }
                if now - reported >= .seconds(10) {
                    reported = now
                    Log.background.info("Watchdog: \((now - start) / .seconds(1)) s, \(hangs) hangs over 100 ms, worst \(Int(worst)) ms, total \(Int(total)) ms")
                }
            }
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
            // Choosing the drive again would give it a new ID and forget its records.
            if let current = DriveDestination.open() {
                defer { DriveDestination.close(current) }
                if current.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path {
                    return Log.background.info("Test drive already Documents/\(name, privacy: .public)")
                }
            }
            try SettingsStore().setDrive(folder: folder)
            Log.background.info("Test drive set to Documents/\(name, privacy: .public)")
        } catch {
            Log.background.error("Couldn't set the test drive: \(error, privacy: .public)")
        }
    }
}
#endif
