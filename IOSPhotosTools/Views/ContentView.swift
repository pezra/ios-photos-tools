import Photos
import SwiftUI
import SyncKit

struct ContentView: View {
    @Environment(BackupStatus.self) private var status
    @Environment(SettingsStore.self) private var settings
    @Environment(DriveStatus.self) private var drive
    @Environment(SyncStatus.self) private var sync
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
                        Text("Photos Tools needs full access to your library to back it up.")
                    }
                } else if status.authorization == .limited {
                    Section {
                        Text("Only the photos you've selected will be backed up. Allow full access in Settings to back up everything.")
                            .font(.footnote)
                    }
                }

                Section {
                    CoverageSummary(coverage: status.coverage, hasCloud: settings.isConfigured, hasDrive: settings.driveName != nil)
                    if settings.isConfigured {
                        cloudRow
                    }
                    if settings.driveName != nil {
                        driveRow
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text(footer)
                }

                if settings.syncEnabled {
                    Section {
                        syncRow
                    } header: {
                        Text("Sync to phone")
                    } footer: {
                        Text("Smaller copies of the pictures in storage, in the \(LibrarySyncEngine.albumTitle) album. They aren't backed up, and ones you delete don't come back.")
                    }
                }

                Section {
                    NavigationLink("Find duplicate photos") { CleanupView() }
                        .disabled(!PhotoLibrary.isAuthorized)
                    NavigationLink("Trip albums") { TripsView() }
                        .disabled(!PhotoLibrary.isAuthorized)
                } footer: {
                    Text("Photos you delete stay in your bucket if they've already been backed up.")
                }
            }
            .navigationTitle("Photos Tools")
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

    private var cloudRow: some View {
        DestinationRow(
            title: "Cloud",
            systemImage: "cloud",
            phase: status.phase,
            details: [
                status.uploading > 0 ? "\(status.uploading) uploading" : nil,
                status.failed > 0 ? "\(status.failed) failed (will retry)" : nil,
            ],
            lastFinished: status.lastFinished,
            error: status.lastError,
            isRunning: status.isRunning,
            canStart: PhotoLibrary.isAuthorized,
            start: { BackupEngine.start() },
            stop: { BackupEngine.stop() }
        )
    }

    private var driveRow: some View {
        DestinationRow(
            title: "USB drive",
            systemImage: "externaldrive",
            phase: drive.isRunning || drive.isConnected ? drive.phase : "Not connected",
            details: [],
            lastFinished: drive.lastFinished,
            error: drive.lastError,
            isRunning: drive.isRunning,
            canStart: drive.isConnected && PhotoLibrary.isAuthorized,
            start: { DriveBackupEngine.start() },
            stop: { DriveBackupEngine.stop() }
        )
    }

    private var syncRow: some View {
        DestinationRow(
            title: "This phone",
            systemImage: "iphone",
            phase: sync.phase,
            details: [
                sync.isRunning && sync.remaining > 0 ? "\(sync.remaining) to go" : nil,
                sync.failed > 0 ? "\(sync.failed) failed (will retry)" : nil,
            ],
            lastFinished: sync.lastFinished,
            error: sync.lastError,
            isRunning: sync.isRunning,
            canStart: PhotoLibrary.hasFullAccess,
            startTitle: "Sync now",
            start: { LibrarySyncEngine.startFromUI() },
            stop: { LibrarySyncEngine.stop() }
        )
    }

    private var footer: String {
        var parts: [String] = []
        if settings.isConfigured {
            parts.append("Uploads continue in the background, and remaining photos are backed up in the background from time to time.")
        }
        if settings.driveName != nil && settings.driveAutoBackup {
            parts.append("The USB drive is backed up automatically when it's plugged in while this app is open.")
        }
        return parts.joined(separator: " ")
    }

    private func requestPhotoAccess() async {
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            status.refresh()
            if settings.autoBackup { BackupEngine.start() }
            if settings.tripAlbums { TripsModel.shared.start() }
        } else {
            // The app becoming active has just listed the library.
            status.refresh(relist: false)
        }
    }
}

/// A bar and counts showing how many photos are backed up nowhere, to one place, or everywhere.
private struct CoverageSummary: View {
    let coverage: BackupStore.Coverage
    let hasCloud: Bool
    let hasDrive: Bool

    private struct Slice: Identifiable {
        let label: String
        let count: Int
        let color: Color
        var id: String { label }
    }

    private var slices: [Slice] {
        switch (hasCloud, hasDrive) {
        case (true, true):
            [
                Slice(label: "Both", count: coverage.both, color: .green),
                Slice(label: "Cloud only", count: coverage.cloudOnly, color: .orange),
                Slice(label: "USB drive only", count: coverage.driveOnly, color: .yellow),
                Slice(label: "Not backed up", count: coverage.nowhere, color: .red),
            ]
        case (true, false):
            [
                Slice(label: "Backed up", count: coverage.cloud, color: .green),
                Slice(label: "Not backed up", count: coverage.total - coverage.cloud, color: .red),
            ]
        case (false, true):
            [
                Slice(label: "Backed up", count: coverage.drive, color: .green),
                Slice(label: "Not backed up", count: coverage.total - coverage.drive, color: .red),
            ]
        case (false, false):
            [Slice(label: "Not backed up", count: coverage.total, color: .red)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(slices) { slice in
                        slice.color.frame(width: width(of: slice, in: geometry.size.width))
                    }
                }
            }
            .frame(height: 10)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
            .accessibilityHidden(true)

            ForEach(slices) { slice in
                LabeledContent {
                    Text(slice.count, format: .number)
                        .monospacedDigit()
                } label: {
                    Label {
                        Text(slice.label)
                    } icon: {
                        Circle().fill(slice.color).frame(width: 10, height: 10)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func width(of slice: Slice, in total: CGFloat) -> CGFloat {
        coverage.total == 0 ? 0 : total * CGFloat(slice.count) / CGFloat(coverage.total)
    }
}

/// One backup destination's progress, with a button to start or pause it.
private struct DestinationRow: View {
    let title: String
    let systemImage: String
    let phase: String
    let details: [String?]
    let lastFinished: Date?
    let error: String?
    let isRunning: Bool
    let canStart: Bool
    var startTitle = "Back up now"
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if isRunning {
                    Button("Pause", role: .destructive, action: stop)
                } else {
                    Button(startTitle, action: start).disabled(!canStart)
                }
            }
            .buttonStyle(.borderless)

            Text(([phase] + details.compactMap { $0 }).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let lastFinished {
                Text("Last completed \(lastFinished, format: .relative(presentation: .named))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
