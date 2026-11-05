import Observation
import Photos
import TripKit

/// Finds trips in the library and keeps an album of the best photos from each one. The user can
/// change what's in an album here or in Photos, and those changes stick.
@MainActor
@Observable
final class TripsModel {
    static let shared = TripsModel()

    struct Trip: Identifiable {
        let id: UUID
        let detected: DetectedTrip
        let stored: StoredTrip
        let title: String

        var hasAlbum: Bool { stored.albumID != nil }
        /// The photos in the album, as of the last sync or edit.
        var albumPhotos: Set<String> { Set(stored.written) }
    }

    /// Name of the Photos folder that holds the albums.
    private static let folderTitle = "Trips"

    private(set) var isSyncing = false
    private(set) var phase = "Not checked yet"
    private(set) var lastError: String?
    /// Newest first.
    private(set) var trips: [Trip] = []

    private var stored = TripStore.load() {
        didSet { if stored != oldValue { TripStore.save(stored) } }
    }
    private var detected: [UUID: DetectedTrip] = [:]
    private var order: [UUID] = []
    private var sync: Task<Void, Never>?
    /// Album reads and writes run one at a time, so an edit can't interleave with a sync.
    private var albumQueue: Task<Void, Never>?

    private var folderID: String? {
        get { UserDefaults.standard.string(forKey: "tripsFolderID") }
        set { UserDefaults.standard.set(newValue, forKey: "tripsFolderID") }
    }

    private init() {}

    func trip(_ id: UUID) -> Trip? {
        trips.first { $0.id == id }
    }

    // MARK: - Syncing

    func start() {
        guard sync == nil else { return }
        sync = Task {
            await performSync()
            sync = nil
        }
    }

    /// Starts a sync if one isn't running, and waits for it to finish.
    func syncNow() async {
        start()
        await sync?.value
    }

    func stop() {
        sync?.cancel()
    }

    private func performSync() async {
        guard PhotoLibrary.isAuthorized else {
            phase = "Photo access needed"
            return
        }
        isSyncing = true
        lastError = nil
        phase = "Looking for trips…"
        defer { isSyncing = false }

        let (found, modified) = await Task.detached {
            let library = Self.fetchLibrary()
            return (TripDetector.trips(library.photos, now: Date()), library.modified)
        }.value
        match(found)

        let autoCreate = SettingsStore.tripAlbums
        for id in order {
            guard !Task.isCancelled, let trip = detected[id], let saved = stored[id] else { continue }
            let wanted = saved.albumID != nil
                || (autoCreate && trip.isFinished && !saved.declined)
            if wanted { await refresh(id, modified: modified) }
        }
        publish()

        if Task.isCancelled {
            phase = "Paused"
        } else if lastError != nil {
            phase = "Done, with errors"
        } else {
            phase = trips.isEmpty ? "No trips found" : "Up to date"
        }
    }

    /// Pairs newly detected trips with the ones already known, by overlapping dates.
    private func match(_ found: [DetectedTrip]) {
        var claimed = Set<UUID>()
        var detected: [UUID: DetectedTrip] = [:]
        for trip in found {
            let known = stored.values.first { !claimed.contains($0.id) && $0.start <= trip.end && trip.start <= $0.end }
            var saved = known ?? StoredTrip(start: trip.start, end: trip.end)
            saved.start = trip.start
            saved.end = trip.end
            stored[saved.id] = saved
            claimed.insert(saved.id)
            detected[saved.id] = trip
        }
        // Forget trips that are gone (their photos were deleted, say) unless they have an album.
        for id in stored.keys where !claimed.contains(id) && stored[id]?.albumID == nil {
            stored[id] = nil
        }
        self.detected = detected
        order = detected.keys.sorted { detected[$0]!.start > detected[$1]!.start }
        publish()
    }

    /// Brings one trip's album up to date: notices changes made in Photos, re-picks if the trip's
    /// photos changed, and writes the album. Creates the album if there isn't one.
    private func refresh(_ id: UUID, modified: [String: Double]? = nil) async {
        guard let trip = detected[id] else { return }
        await withAlbumQueue { self.reconcile(id) }
        // The user deleted the album in Photos.
        guard stored[id]?.declined == false else { return publish() }

        let fingerprint = Self.fingerprint(trip, modified: modified ?? Self.modificationDates(trip.photoIDs))
        if stored[id]?.picksFingerprint != fingerprint {
            guard let picks = await pick(trip, title: title(id)) else { return }
            stored[id]?.picks = picks
            stored[id]?.picksFingerprint = fingerprint
        }
        if stored[id]?.placeTitle == nil {
            stored[id]?.placeTitle = await placeTitle(trip)
        }
        // Again, in case the album changed in Photos while photos were being analyzed.
        await withAlbumQueue {
            self.reconcile(id)
            await self.write(id)
        }
        publish()
    }

    /// Chooses photos from each site, analyzing any that haven't been yet. Nil if cancelled.
    private func pick(_ trip: DetectedTrip, title: String) async -> [String]? {
        let ids = trip.photoIDs
        var assets: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            assets[asset.localIdentifier] = asset
        }
        var analyses = AnalysisStore.shared.analyses(ids)
        let pending = assets.values.filter {
            LibraryAnalyzer.needsAnalysis($0, cached: analyses[$0.localIdentifier], minVersion: PhotoAnalyzer.version)
        }
        var done = 0
        if !pending.isEmpty { phase = "Analyzing \(title) (0 of \(pending.count))" }
        await LibraryAnalyzer.analyze(pending) { id, result in
            switch result {
            case .success(let analysis): analyses[id] = analysis
            case .failure(let error): lastError = error.localizedDescription
            }
            done += 1
            phase = "Analyzing \(title) (\(done) of \(pending.count))"
        }
        guard !Task.isCancelled else { return nil }

        return trip.sites.flatMap { site in
            let candidates = site.photoIDs.compactMap { id -> Candidate? in
                guard let asset = assets[id], let analysis = analyses[id] else { return nil }
                return Candidate(analysis: analysis, asset: asset)
            }
            // Keep only the best of each set of retakes, so a site's picks aren't the same shot.
            let retakes = Set(DuplicateGrouper.groups(candidates).flatMap { $0.assetIDs.dropFirst() })
            let shots = candidates.filter { !retakes.contains($0.id) }.map { c in
                let a = c.analysis
                return PickCandidate(id: c.id, aesthetics: a.aesthetics, isUtility: a.isUtility,
                                     faceCount: a.faceCount, faceArea: a.faceArea, personArea: a.personArea,
                                     faceQuality: a.faceQuality, sharpness: a.sharpness,
                                     isFavorite: c.isFavorite, isEdited: c.isEdited, featurePrint: a.featurePrint)
            }
            return TripPicker.picks(shots)
        }
    }

    /// Names the trip after the towns where most of its photos were taken, e.g. "Lisbon & Sintra".
    private func placeTitle(_ trip: DetectedTrip) async -> String? {
        var cities: [String] = []
        var lookedUp = 0
        for site in trip.sites.sorted(by: { $0.photoIDs.count > $1.photoIDs.count }).prefix(4) {
            guard let place = await PlaceNames.shared.place(at: site.center) else { continue }
            lookedUp += 1
            if let city = place.city, !cities.contains(city) { cities.append(city) }
        }
        // Try again next time if every lookup failed (offline, say).
        guard lookedUp > 0 else { return nil }
        return cities.isEmpty ? "Trip" : cities.prefix(2).joined(separator: " & ")
    }

    // MARK: - Editing

    /// Puts a photo in the trip's album or takes it out.
    func setIncluded(_ assetID: String, _ included: Bool, in id: UUID) async {
        await edit(id) { trip in
            if included {
                trip.added.insert(assetID)
                trip.removed.remove(assetID)
            } else {
                trip.removed.insert(assetID)
                trip.added.remove(assetID)
            }
        }
    }

    /// Drops the user's changes to one site, or to the whole trip if `site` is nil.
    func resetToAutomatic(_ id: UUID, site: Site? = nil) async {
        await edit(id) { trip in
            if let site {
                trip.added.subtract(site.photoIDs)
                trip.removed.subtract(site.photoIDs)
            } else {
                trip.added = []
                trip.removed = []
            }
        }
    }

    func rename(_ id: UUID, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await edit(id) { $0.customTitle = title.isEmpty ? nil : title }
    }

    /// Makes an album for a trip that doesn't have one: one still going, one whose album the
    /// user deleted, or any trip while automatic albums are turned off.
    func createAlbum(_ id: UUID) async {
        stored[id]?.declined = false
        await refresh(id)
    }

    private func edit(_ id: UUID, _ change: @escaping (inout StoredTrip) -> Void) async {
        await withAlbumQueue {
            self.reconcile(id)
            guard self.stored[id] != nil else { return }
            change(&self.stored[id]!)
            await self.write(id)
        }
        publish()
    }

    // MARK: - Albums

    private func withAlbumQueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = albumQueue
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        albumQueue = task
        await task.value
    }

    /// Records changes the user made to the album in Photos since it was last written: photos
    /// added or removed, a new title, or the album deleted.
    private func reconcile(_ id: UUID) {
        guard var trip = stored[id], let albumID = trip.albumID else { return }
        guard let album = Self.album(albumID) else {
            trip.albumID = nil
            trip.written = []
            trip.writtenTitle = nil
            trip.declined = true
            stored[id] = trip
            return
        }

        let current = Self.assetIDs(in: album)
        let written = Set(trip.written)
        let addedThere = Set(current).subtracting(written)
        let removedThere = written.subtracting(current)
        trip.added.formUnion(addedThere)
        trip.removed.subtract(addedThere)
        trip.removed.formUnion(removedThere)
        trip.added.subtract(removedThere)
        trip.written = current

        if let title = album.localizedTitle, title != trip.writtenTitle {
            trip.customTitle = title
            trip.writtenTitle = title
        }
        stored[id] = trip
    }

    /// Makes the album match what the trip should hold, creating it if needed.
    private func write(_ id: UUID) async {
        guard let trip = stored[id] else { return }
        let title = title(id)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let wanted = PHAsset.fetchAssets(withLocalIdentifiers: Array(trip.wanted), options: options)
        let wantedIDs = Self.assetIDs(of: wanted)

        do {
            if let albumID = trip.albumID, let album = Self.album(albumID) {
                let current = PHAsset.fetchAssets(in: album, options: nil)
                let changesPhotos = Set(Self.assetIDs(of: current)) != Set(wantedIDs)
                let changesTitle = album.localizedTitle != title
                if changesPhotos || changesTitle {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCollectionChangeRequest(for: album, assets: current)
                        if changesPhotos {
                            // Rewritten whole so the album stays in the order the photos were taken.
                            request?.removeAssets(current)
                            request?.addAssets(wanted)
                        }
                        if changesTitle { request?.title = title }
                    }
                }
            } else {
                guard !wantedIDs.isEmpty else { return }
                let folder = folderID.flatMap { PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [$0], options: nil).firstObject }
                let created = CreatedIDs()
                let folderTitle = Self.folderTitle
                try await PHPhotoLibrary.shared().performChanges {
                    let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                    album.addAssets(wanted)
                    let placeholder = album.placeholderForCreatedAssetCollection
                    created.album = placeholder.localIdentifier
                    if let folder, let request = PHCollectionListChangeRequest(for: folder) {
                        request.addChildCollections([placeholder] as NSArray)
                    } else {
                        let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: folderTitle)
                        request.addChildCollections([placeholder] as NSArray)
                        created.folder = request.placeholderForCreatedCollectionList.localIdentifier
                    }
                }
                stored[id]?.albumID = created.album
                if let newFolder = created.folder { folderID = newFolder }
            }
            stored[id]?.written = wantedIDs
            stored[id]?.writtenTitle = title
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Filled in by a change block, which Photos runs on its own queue.
    private final class CreatedIDs: @unchecked Sendable {
        var album: String?
        var folder: String?
    }

    // MARK: - Helpers

    private func title(_ id: UUID) -> String {
        guard let trip = stored[id] else { return "Trip" }
        if let custom = trip.customTitle { return custom }
        return "\(trip.placeTitle ?? "Trip") · \(Self.months(from: trip.start, to: trip.end))"
    }

    /// Rebuilds `trips` for the views.
    private func publish() {
        trips = order.compactMap { id in
            guard let trip = detected[id], let saved = stored[id] else { return nil }
            return Trip(id: id, detected: trip, stored: saved, title: title(id))
        }
    }

    /// "May 2026", "Apr – May 2026" or "Dec 2025 – Jan 2026".
    static func months(from start: Date, to end: Date) -> String {
        let calendar = Calendar.current
        let monthYear = Date.FormatStyle().month(.abbreviated).year()
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return start.formatted(monthYear)
        }
        if calendar.isDate(start, equalTo: end, toGranularity: .year) {
            return "\(start.formatted(.dateTime.month(.abbreviated))) – \(end.formatted(monthYear))"
        }
        return "\(start.formatted(monthYear)) – \(end.formatted(monthYear))"
    }

    private static func album(_ id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private static func assetIDs(in album: PHAssetCollection) -> [String] {
        assetIDs(of: PHAsset.fetchAssets(in: album, options: nil))
    }

    private static func assetIDs(of assets: PHFetchResult<PHAsset>) -> [String] {
        var ids: [String] = []
        assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    /// Changes when a photo joins or leaves the trip, or is edited, so picks are only redone then.
    private static func fingerprint(_ trip: DetectedTrip, modified: [String: Double]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for id in trip.photoIDs.sorted() {
            for byte in "\(id)@\(modified[id] ?? 0);".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }

    private static func modificationDates(_ ids: [String]) -> [String: Double] {
        var dates: [String: Double] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            dates[asset.localIdentifier] = asset.modificationDate?.timeIntervalSince1970
        }
        return dates
    }

    /// Every visible photo's date and place, skipping screenshots and low-res copies synced from
    /// storage. Bursts count once.
    nonisolated private static func fetchLibrary() -> (photos: [TripPhoto], modified: [String: Double]) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        var photos: [TripPhoto] = []
        var modified: [String: Double] = [:]
        PhotoLibrary.enumerateOwnAssets(PHAsset.fetchAssets(with: options)) { asset in
            guard let date = asset.creationDate, !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            let coordinate = asset.location.map {
                Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
            photos.append(TripPhoto(id: asset.localIdentifier, date: date, coordinate: coordinate))
            modified[asset.localIdentifier] = asset.modificationDate?.timeIntervalSince1970
        }
        return (photos, modified)
    }
}
