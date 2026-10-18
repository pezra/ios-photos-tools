import S3Kit
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: Result<String, Error>?
    @State private var isTesting = false
    @State private var confirmingReset = false

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
                    Button("Forget backup history", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("Makes the next backup upload everything again. Use this after switching to a different bucket.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .confirmationDialog("Upload your whole library again?", isPresented: $confirmingReset, titleVisibility: .visible) {
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
            let key = [snapshot.prefix, ".backup-test"].filter { !$0.isEmpty }.joined(separator: "/")
            try await client.putObject(key: key, data: Data("Photo Backup connection test\n".utf8), contentType: "text/plain")
            testResult = .success("Wrote \(key)")
        } catch {
            testResult = .failure(error)
        }
    }
}

private extension View {
    func plainInput() -> some View {
        textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}
