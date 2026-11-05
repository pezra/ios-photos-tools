import S3Kit
import SwiftUI
import SyncKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: Result<String, Error>?
    @State private var isTesting = false
    @State private var confirmingReset = false
    @State private var choosingDriveFolder = false
    @State private var driveError: String?
    @State private var isCheckingSync = false
    @State private var confirmingSync = false
    @State private var pendingSync = 0
    @State private var syncError: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    TextField("Endpoint URL", text: $settings.endpoint, prompt: Text("https://s3.us-east-1.amazonaws.com"))
                        .keyboardType(.URL)
                        .plainInput()
                    LabeledContent("Region") {
                        TextField("Region", text: $settings.region, prompt: Text("us-east-1"))
                            .multilineTextAlignment(.trailing)
                            .plainInput()
                    }
                    LabeledContent("Bucket") {
                        TextField("Bucket", text: $settings.bucket)
                            .multilineTextAlignment(.trailing)
                            .plainInput()
                    }
                    LabeledContent("Folder") {
                        TextField("Key prefix", text: $settings.prefix, prompt: Text("photos"))
                            .multilineTextAlignment(.trailing)
                            .plainInput()
                    }
                    Toggle("Path-style URLs", isOn: $settings.usePathStyle)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Works with AWS S3 and S3-compatible services. Use region \"auto\" for Cloudflare R2. Leave path-style on unless your provider requires bucket subdomains.")
                }

                Section("Credentials") {
                    TextField("Access key ID", text: $settings.accessKeyID)
                        .plainInput()
                    SecureField("Secret access key", text: $settings.secretAccessKey)
                        .plainInput()
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting || !settings.isConfigured)
                    switch testResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let error):
                        Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                } footer: {
                    Text("Uploads a small test file to the folder above.")
                }

                Section("Options") {
                    Toggle("Back up automatically", isOn: $settings.autoBackup)
                    Toggle("Use cellular data", isOn: $settings.allowCellular)
                }

                Section {
                    if let driveName = settings.driveName {
                        LabeledContent("Folder", value: driveName)
                        Toggle("Back up when connected", isOn: $settings.driveAutoBackup)
                        Button("Choose a different folder") { choosingDriveFolder = true }
                        Button("Stop backing up to this drive", role: .destructive) { settings.forgetDrive() }
                    } else {
                        Button("Choose folder on drive…") { choosingDriveFolder = true }
                    }
                    if let driveError {
                        Label(driveError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                } header: {
                    Text("USB drive")
                } footer: {
                    Text("Plug in the drive, then pick your pictures folder on it. Photos are copied into its year folders whenever the drive is plugged in while Photos Tools is open, and keep copying if you leave the app.")
                }

                Section {
                    if settings.syncEnabled {
                        Toggle("Sync pictures to this phone", isOn: $settings.syncEnabled)
                    } else {
                        Button {
                            Task { await checkSync() }
                        } label: {
                            HStack {
                                Text("Set up sync…")
                                if isCheckingSync { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isCheckingSync)
                    }
                    if let syncError {
                        Label(syncError, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                } header: {
                    Text("Sync to phone")
                } footer: {
                    Text("Keeps a smaller copy of every picture on the drive and in the bucket in your Photos library, in the \(LibrarySyncEngine.albumTitle) album. Originals stay in storage. Needs full photo access.")
                }

                Section {
                    Toggle("Make trip albums automatically", isOn: $settings.tripAlbums)
                } header: {
                    Text("Trip albums")
                } footer: {
                    Text("When you get back from a trip, an album of the best photos from each place you visited is added to the Trips folder in Photos.")
                }

                Section {
                    Button("Forget backup history", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("Makes the next backup check every photo again and upload whatever isn't in the bucket. Use this after switching to a different bucket.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .fileImporter(isPresented: $choosingDriveFolder, allowedContentTypes: [.folder]) { result in
                do {
                    try settings.setDrive(folder: result.get())
                    driveError = nil
                } catch {
                    driveError = error.localizedDescription
                }
            }
            .confirmationDialog("Sync \(pendingSync) pictures to this phone?", isPresented: $confirmingSync, titleVisibility: .visible) {
                Button("Start sync") { startSync() }
            } message: {
                Text(syncConfirmation)
            }
            .confirmationDialog("Check your whole library again?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Forget backup history", role: .destructive) {
                    BackupStore.shared.reset()
                    BackupStatus.shared.refreshCounts()
                }
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        guard let snapshot = SettingsStore.snapshot() else { return }
        do {
            let client = try S3Client(config: snapshot.s3)
            let key = LibraryPath.key(prefix: snapshot.prefix, path: ".backup-test")
            try await client.putObject(key: key, data: Data("Photos Tools connection test\n".utf8), contentType: "text/plain")
            _ = try await client.listObjects(prefix: key)
            _ = try await client.getObject(key: key)
            testResult = .success("Wrote, listed and read \(key)")
        } catch let error as S3Error where error.status == 403 {
            testResult = .failure(ConnectionError.needsReadAccess(error))
        } catch {
            testResult = .failure(error)
        }
    }

    private enum ConnectionError: Error, LocalizedError {
        case needsReadAccess(S3Error)

        var errorDescription: String? {
            switch self {
            case let .needsReadAccess(error): "These keys need s3:PutObject, s3:GetObject and s3:ListBucket. \(error.localizedDescription)"
            }
        }
    }

    private func checkSync() async {
        isCheckingSync = true
        syncError = nil
        defer { isCheckingSync = false }
        guard PhotoLibrary.hasFullAccess else {
            syncError = "Allow full photo access in the Settings app first."
            return
        }
        do {
            pendingSync = try await LibrarySyncEngine.shared.countPending()
            confirmingSync = true
        } catch {
            syncError = error.localizedDescription
        }
    }

    private var syncConfirmation: String {
        let size = Int64(pendingSync) * LibrarySyncEngine.estimatedBytesPerPicture
        let estimate = size.formatted(.byteCount(style: .file))
        let drive = DriveDestination.isConnected
            ? ""
            : " The drive isn't connected, so pictures would be downloaded from the bucket, which your provider may charge for. Plug it in first to avoid that."
        return "This adds about \(estimate) to your Photos library. If iCloud Photos is on, the copies also upload to iCloud and count against your storage.\(drive)"
    }

    private func startSync() {
        settings.syncEnabled = true
        LibrarySyncEngine.startFromUI()
    }
}

private extension View {
    func plainInput() -> some View {
        textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}
