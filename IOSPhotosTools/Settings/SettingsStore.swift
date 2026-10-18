import Foundation
import Observation
import S3Kit

private enum Key {
    static let endpoint = "endpoint"
    static let region = "region"
    static let bucket = "bucket"
    static let prefix = "prefix"
    static let usePathStyle = "usePathStyle"
    static let allowCellular = "allowCellular"
    static let autoBackup = "autoBackup"
    static let driveAutoBackup = "driveAutoBackup"
    static let accessKeyID = "accessKeyID"
    static let secretAccessKey = "secretAccessKey"
}

/// User-editable settings. Non-secret values live in UserDefaults; credentials in the Keychain.
@Observable
final class SettingsStore {
    private static let defaults = UserDefaults.standard

    var endpoint: String { didSet { Self.defaults.set(endpoint, forKey: Key.endpoint) } }
    var region: String { didSet { Self.defaults.set(region, forKey: Key.region) } }
    var bucket: String { didSet { Self.defaults.set(bucket, forKey: Key.bucket) } }
    var prefix: String { didSet { Self.defaults.set(prefix, forKey: Key.prefix) } }
    var usePathStyle: Bool { didSet { Self.defaults.set(usePathStyle, forKey: Key.usePathStyle) } }
    var allowCellular: Bool { didSet { Self.defaults.set(allowCellular, forKey: Key.allowCellular) } }
    var autoBackup: Bool { didSet { Self.defaults.set(autoBackup, forKey: Key.autoBackup) } }
    var driveAutoBackup: Bool { didSet { Self.defaults.set(driveAutoBackup, forKey: Key.driveAutoBackup) } }
    /// The backup drive folder's display name, or nil if none is set up.
    private(set) var driveName: String?
    var accessKeyID: String { didSet { Keychain.set(accessKeyID, for: Key.accessKeyID) } }
    var secretAccessKey: String { didSet { Keychain.set(secretAccessKey, for: Key.secretAccessKey) } }

    init() {
        Self.registerDefaults()
        let d = Self.defaults
        endpoint = d.string(forKey: Key.endpoint) ?? ""
        region = d.string(forKey: Key.region) ?? ""
        bucket = d.string(forKey: Key.bucket) ?? ""
        prefix = d.string(forKey: Key.prefix) ?? ""
        usePathStyle = d.bool(forKey: Key.usePathStyle)
        allowCellular = d.bool(forKey: Key.allowCellular)
        autoBackup = d.bool(forKey: Key.autoBackup)
        driveAutoBackup = d.bool(forKey: Key.driveAutoBackup)
        driveName = DriveDestination.name
        accessKeyID = Keychain.get(Key.accessKeyID) ?? ""
        secretAccessKey = Keychain.get(Key.secretAccessKey) ?? ""
    }

    var isConfigured: Bool {
        let required = [endpoint, region, bucket, accessKeyID, secretAccessKey]
        return required.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    func setDrive(folder: URL) throws {
        try DriveDestination.configure(folder: folder)
        BackupStore.shared.forgetDrives(except: DriveDestination.id)
        driveName = DriveDestination.name
    }

    func forgetDrive() {
        DriveDestination.forget()
        BackupStore.shared.forgetDrives(except: nil)
        driveName = nil
    }

    // MARK: - Thread-safe access for the backup engine

    static var driveAutoBackup: Bool {
        registerDefaults()
        return defaults.bool(forKey: Key.driveAutoBackup)
    }

    struct Snapshot: Sendable {
        let s3: S3Config
        let prefix: String
        let allowCellular: Bool
        let autoBackup: Bool
    }

    /// Reads the persisted settings directly, so it can be called from any thread.
    static func snapshot() -> Snapshot? {
        registerDefaults()
        let d = defaults
        func value(_ key: String) -> String? {
            let v = d.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return v?.isEmpty == false ? v : nil
        }
        guard let endpointString = value(Key.endpoint),
              let endpoint = URL(string: endpointString),
              let region = value(Key.region),
              let bucket = value(Key.bucket),
              let accessKeyID = Keychain.get(Key.accessKeyID), !accessKeyID.isEmpty,
              let secret = Keychain.get(Key.secretAccessKey), !secret.isEmpty
        else { return nil }
        return Snapshot(
            s3: S3Config(
                endpoint: endpoint,
                region: region,
                bucket: bucket,
                accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
                secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                usePathStyle: d.bool(forKey: Key.usePathStyle)
            ),
            prefix: (value(Key.prefix) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            allowCellular: d.bool(forKey: Key.allowCellular),
            autoBackup: d.bool(forKey: Key.autoBackup)
        )
    }

    private static func registerDefaults() {
        defaults.register(defaults: [
            Key.region: "us-east-1",
            Key.prefix: "photos",
            Key.usePathStyle: true,
            Key.allowCellular: false,
            Key.autoBackup: true,
            Key.driveAutoBackup: true,
        ])
    }
}
