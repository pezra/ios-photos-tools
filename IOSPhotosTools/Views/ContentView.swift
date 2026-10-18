import Photos
import SwiftUI

struct ContentView: View {
    @Environment(BackupStatus.self) private var status
    @Environment(SettingsStore.self) private var settings
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                if !settings.isConfigured {
                    Section {
                        Button("Set up storage") { showingSettings = true }
                    } footer: {
                        Text("Enter your S3 endpoint, bucket and access keys to start backing up.")
                    }
                }

                if status.authorization == .denied || status.authorization == .restricted {
                    Section {
                        Button("Allow photo access in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } footer: {
                        Text("Photo Backup needs full access to your library to back it up.")
                    }
                } else if status.authorization == .limited {
                    Section {
                        Text("Only the photos you've selected will be backed up. Allow full access in Settings to back up everything.")
                            .font(.footnote)
                    }
                }

                Section("Backup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(status.completedAssets) of \(status.totalAssets) items backed up")
                        ProgressView(value: progress)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Status", value: status.phase)
                    LabeledContent("Uploading", value: "\(status.uploading) files")
                    if status.failed > 0 {
                        LabeledContent("Failed (will retry)", value: "\(status.failed) files")
                    }
                    if let lastFinished = status.lastFinished {
                        LabeledContent("Last completed") {
                            Text(lastFinished, format: .relative(presentation: .named))
                        }
                    }
                }

                if let error = status.lastError {
                    Section("Last error") {
                        Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                }

                Section {
                    if status.isRunning {
                        Button("Pause", role: .destructive) { BackupEngine.stop() }
                    } else {
                        Button("Back up now") { BackupEngine.start() }
                            .disabled(!settings.isConfigured || !PhotoLibrary.isAuthorized)
                    }
                } footer: {
                    Text("Uploads continue in the background. Remaining photos are also backed up in the background from time to time, even when your phone isn't charging.")
                }

                Section {
                    NavigationLink("Find duplicate photos") { CleanupView() }
                        .disabled(!PhotoLibrary.isAuthorized)
                } footer: {
                    Text("Photos you delete stay in your bucket if they've already been backed up.")
                }
            }
            .navigationTitle("Photo Backup")
            .toolbar {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                status.refresh()
                if settings.autoBackup { BackupEngine.start() }
            }) {
                SettingsView()
            }
            .task { await requestPhotoAccess() }
        }
    }

    private var progress: Double {
        status.totalAssets == 0 ? 0 : Double(status.completedAssets) / Double(status.totalAssets)
    }

    private func requestPhotoAccess() async {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            status.refresh()
            if settings.autoBackup { BackupEngine.start() }
        } else {
            status.refresh()
        }
    }
}
