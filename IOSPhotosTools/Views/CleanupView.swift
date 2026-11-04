import Photos
import SwiftUI

/// Groups of near-duplicate photos, with the best of each kept and the rest marked for deletion.
struct CleanupView: View {
    @State private var model = CleanupModel.shared
    @State private var looseness = CleanupModel.shared.looseness
    @State private var deleting = false

    var body: some View {
        List {
            Section {
                if model.isScanning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.phase)
                        ProgressView(value: progress)
                    }
                    .padding(.vertical, 4)
                    Button("Pause", role: .destructive) { model.stop() }
                } else {
                    LabeledContent("Status", value: model.phase)
                    Picker("Look at", selection: $model.scope) {
                        Text("Recent photos").tag(CleanupModel.Scope.recent)
                        Text("Whole library").tag(CleanupModel.Scope.wholeLibrary)
                    }
                    .pickerStyle(.segmented)
                    Button(model.groups.isEmpty ? "Scan library" : "Rescan") { model.start() }
                        .disabled(!PhotoLibrary.isAuthorized)
                }
            } footer: {
                Text(scopeDescription)
            }

            if let error = model.lastError {
                Section("Last error") {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section {
                VStack(alignment: .leading) {
                    Slider(value: $looseness, in: 0...1) { editing in
                        if !editing { model.looseness = looseness }
                    }
                    HStack {
                        Text("Near-identical")
                        Spacer()
                        Text("Similar")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Match")
            } footer: {
                Text("Tap a photo to keep or delete it. Photos you keep won't be suggested for deletion again. Touch and hold to see a photo larger.")
            }

            ForEach(model.groups) { group in
                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(group.assetIDs, id: \.self) { id in
                                GroupPhoto(assetID: id, isBest: id == group.best, isMarked: model.marked.contains(id))
                                    .onTapGesture { model.toggle(id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .navigationTitle("Duplicates")
        .safeAreaInset(edge: .bottom) {
            if model.markedCount > 0 && !model.isScanning {
                Button(role: .destructive) {
                    deleting = true
                    Task {
                        await model.deleteMarked()
                        deleting = false
                    }
                } label: {
                    Text("Delete \(model.markedCount) photos").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(deleting)
                .padding()
            }
        }
    }

    private var scopeDescription: String {
        switch model.scope {
        case .recent:
            let since = model.recentCutoff.formatted(date: .abbreviated, time: .shortened)
            let reason = model.lastScanStarted == nil ? "the last 30 days" : "your last scan"
            return "Looks at photos taken since \(since) (\(reason)). Photos are analyzed on this phone."
        case .wholeLibrary:
            return "Photos are analyzed on this phone. The first scan of a big library takes a while; later scans only analyze new and edited photos."
        }
    }

    private var progress: Double {
        model.totalCount == 0 ? 0 : Double(model.analyzedCount) / Double(model.totalCount)
    }
}

private struct GroupPhoto: View {
    let assetID: String
    let isBest: Bool
    let isMarked: Bool

    var body: some View {
        Thumbnail(assetID: assetID, size: 110)
            .opacity(isMarked ? 0.45 : 1)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: isMarked ? "trash.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isMarked ? .red : .green)
                    .padding(4)
            }
            .overlay(alignment: .topLeading) {
                if isBest {
                    Text("Best")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(isMarked ? "Keep" : "Delete", systemImage: isMarked ? "checkmark" : "trash") {
                    CleanupModel.shared.toggle(assetID)
                }
            } preview: {
                Thumbnail(assetID: assetID, size: 400, contentMode: .fit)
            }
            .accessibilityLabel(isMarked ? "Marked for deletion" : "Keeping")
            .accessibilityAddTraits(.isButton)
    }
}
