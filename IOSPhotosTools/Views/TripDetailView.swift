import SwiftUI
import TripKit

/// One trip's places and the photos from each that are in its album. Changes go straight to the
/// album.
struct TripDetailView: View {
    let tripID: UUID
    @State private var model = TripsModel.shared
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var working = false

    var body: some View {
        if let trip = model.trip(tripID) {
            content(trip)
        } else {
            ContentUnavailableView("Trip not found", systemImage: "suitcase")
        }
    }

    private func content(_ trip: TripsModel.Trip) -> some View {
        List {
            if !trip.hasAlbum {
                Section {
                    Button {
                        run { await model.createAlbum(tripID) }
                    } label: {
                        HStack {
                            Text("Create album")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working)
                } footer: {
                    Text(noAlbumReason(trip))
                }
            }

            ForEach(Array(trip.detected.sites.enumerated()), id: \.offset) { _, site in
                SiteSection(trip: trip, site: site)
            }
        }
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if trip.hasAlbum {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newTitle = trip.title
                        renaming = true
                    }
                    Button("Reset to automatic picks", systemImage: "arrow.counterclockwise") {
                        run { await model.resetToAutomatic(tripID) }
                    }
                    .disabled(trip.stored.added.isEmpty && trip.stored.removed.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename album", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { run { await model.rename(tripID, to: newTitle) } }
        } message: {
            Text("Leave it empty to go back to the automatic title.")
        }
    }

    private func noAlbumReason(_ trip: TripsModel.Trip) -> String {
        if trip.stored.declined { return "You deleted this trip's album, so it won't be made again unless you ask." }
        if !trip.detected.isFinished { return "This trip looks like it's still going, so its album hasn't been made yet. If you make it now, it keeps up as you take more photos." }
        if !SettingsStore.tripAlbums { return "Automatic trip albums are turned off in Settings." }
        return "This trip's album will be made the next time trips are checked."
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}

/// A place in the trip, with the photos from it that are in the album.
private struct SiteSection: View {
    let trip: TripsModel.Trip
    let site: Site
    @State private var place: PlaceNames.Place?

    private var inAlbum: [String] {
        site.photoIDs.filter { trip.albumPhotos.contains($0) }
    }

    var body: some View {
        Section {
            if trip.hasAlbum {
                if inAlbum.isEmpty {
                    Text("No photos from here are in the album.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(inAlbum, id: \.self) { id in
                                Thumbnail(assetID: id, size: 110)
                                    .contextMenu {
                                        Button("Remove from album", systemImage: "minus.circle", role: .destructive) {
                                            Task { await TripsModel.shared.setIncluded(id, false, in: trip.id) }
                                        }
                                    } preview: {
                                        Thumbnail(assetID: id, size: 400, contentMode: .fit)
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
                NavigationLink("Choose photos (\(site.photoIDs.count))") {
                    SitePhotosView(tripID: trip.id, site: site, title: placeName)
                }
            } else {
                Text(site.photoIDs.count == 1 ? "1 photo" : "\(site.photoIDs.count) photos")
                    .foregroundStyle(.secondary)
            }
        } header: {
            VStack(alignment: .leading) {
                Text(placeName)
                Text(site.start, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(.caption)
                    .textCase(nil)
            }
        }
        .task { place = await PlaceNames.shared.place(at: site.center) }
    }

    private var placeName: String {
        place?.name ?? place?.city ?? "Place"
    }
}

/// Every photo from a place; tap one to put it in the album or take it out.
private struct SitePhotosView: View {
    let tripID: UUID
    let site: Site
    let title: String
    @State private var model = TripsModel.shared

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        let trip = model.trip(tripID)
        let inAlbum = trip?.albumPhotos ?? []
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(site.photoIDs, id: \.self) { id in
                    let included = inAlbum.contains(id)
                    Thumbnail(assetID: id, size: 110)
                        .opacity(included ? 1 : 0.6)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: included ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, included ? Color.accentColor : .black.opacity(0.3))
                                .padding(4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await model.setIncluded(id, !included, in: tripID) }
                        }
                        .contextMenu {
                            Button(included ? "Remove from album" : "Add to album",
                                   systemImage: included ? "minus.circle" : "plus.circle") {
                                Task { await model.setIncluded(id, !included, in: tripID) }
                            }
                        } preview: {
                            Thumbnail(assetID: id, size: 400, contentMode: .fit)
                        }
                        .accessibilityLabel(included ? "In album" : "Not in album")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(4)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Reset") {
                Task { await model.resetToAutomatic(tripID, site: site) }
            }
            .disabled(!hasChanges(trip))
        }
    }

    private func hasChanges(_ trip: TripsModel.Trip?) -> Bool {
        guard let trip else { return false }
        return site.photoIDs.contains { trip.stored.added.contains($0) || trip.stored.removed.contains($0) }
    }
}
