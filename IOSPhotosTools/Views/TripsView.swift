import SwiftUI

/// Trips found in the library, each with its album.
struct TripsView: View {
    @State private var model = TripsModel.shared

    var body: some View {
        List {
            Section {
                HStack {
                    Text(model.phase)
                    if model.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
                if let error = model.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
            } footer: {
                Text("Trips are found from where and when photos were taken. Each trip's album is in the Trips folder in Photos and holds the best photos from each place, ideally one of the people there and one of the place itself.")
            }

            ForEach(model.trips) { trip in
                NavigationLink {
                    TripDetailView(tripID: trip.id)
                } label: {
                    TripRow(trip: trip)
                }
            }
        }
        .navigationTitle("Trip albums")
        .refreshable { await model.syncNow() }
        .task { model.start() }
    }
}

private struct TripRow: View {
    let trip: TripsModel.Trip

    var body: some View {
        HStack(spacing: 12) {
            if let cover = trip.stored.written.first ?? trip.detected.photoIDs.first {
                Thumbnail(assetID: cover, size: 56)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title)
                Text(trip.detected.start ..< max(trip.detected.end, trip.detected.start + 1),
                     format: .interval.day().month(.abbreviated).year())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        let places = trip.detected.sites.count == 1 ? "1 place" : "\(trip.detected.sites.count) places"
        if trip.hasAlbum { return "\(places) · \(trip.stored.written.count) photos in album" }
        if !trip.detected.isFinished { return "\(places) · In progress" }
        return "\(places) · No album"
    }
}
