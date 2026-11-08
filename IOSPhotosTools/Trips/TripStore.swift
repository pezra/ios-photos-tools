import Foundation

/// What the app remembers about a trip between runs: its album, and the changes the user made
/// to the automatic picks (here or in Photos).
struct StoredTrip: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Last detected span. Matched against newly detected trips by overlap.
    var start: Date
    var end: Date
    /// A title the user gave the album, here or by renaming it in Photos.
    var customTitle: String?
    /// Built from place names; nil until reverse geocoding succeeds.
    var placeTitle: String?
    var albumID: String?
    /// The album's title as last written, to notice renames made in Photos.
    var writtenTitle: String?
    /// The photos last put in the album.
    var written: [String] = []
    /// Automatic picks, and a fingerprint of the photos (and their edits) they were picked from.
    var picks: [String] = []
    var picksFingerprint: String?
    /// Photos the user put in the album or took out, which win over the automatic picks.
    var added: Set<String> = []
    var removed: Set<String> = []
    /// The user deleted the album, so another isn't made unless they ask.
    var declined = false

    init(start: Date, end: Date) {
        id = UUID()
        self.start = start
        self.end = end
    }

    /// What the album should hold.
    var wanted: Set<String> { Set(picks).union(added).subtracting(removed) }
}

/// Saves trips as a small JSON file. There are at most a few hundred, so this is plenty.
enum TripStore {
    private static var url: URL {
        AppDirectories.support.appendingPathComponent("trips.json")
    }

    static func load() -> [UUID: StoredTrip] {
        guard let data = try? Data(contentsOf: url),
              let trips = try? JSONDecoder().decode([StoredTrip].self, from: data) else { return [:] }
        return Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    static func save(_ trips: [UUID: StoredTrip]) {
        do {
            try JSONEncoder().encode(Array(trips.values)).write(to: url, options: .atomic)
        } catch {
            print("Couldn't save trips: \(error)")
        }
    }
}
