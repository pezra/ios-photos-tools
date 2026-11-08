import CoreLocation
import os
import Photos
import SyncKit
import TripKit

/// The photo library listed once, for everything that needs it: the backup engines, the coverage
/// counts, trips and cleanup. Listing a big library takes a while, so users ask `current()` instead
/// of listing it themselves.
///
/// A snapshot lasts until `invalidate()`, which the app calls when it becomes active and when
/// something asks for the library to be listed again (photos deleted, access granted, settings
/// closed). So a photo added while the app is open is found at the next activation, not before. A
/// pass reads what it exports from the asset itself, not the snapshot (see `PhotoLibrary.freshAsset`).
final class LibrarySnapshot: @unchecked Sendable {
    /// Every photo and video except low-res copies imported from storage, newest first, and the
    /// matching `PHAsset`s.
    let entries: [LibraryEntry]
    let assets: [PHAsset]

    private init(entries: [LibraryEntry], assets: [PHAsset]) {
        self.entries = entries
        self.assets = assets
    }

    /// The IDs of every asset that gets backed up.
    var ids: [String] { entries.map(\.id) }

    /// Assets that need backing up, given `completed` (asset ID → the asset's modification date
    /// when it was backed up).
    func pending(completed: [String: Double?]) -> [PHAsset] {
        LibraryFilter.pending(entries, completed: completed).map { assets[$0] }
    }

    /// Photos for trip detection, and each one's modification date.
    func tripPhotos() -> (photos: [TripPhoto], modified: [String: Double]) {
        var photos: [TripPhoto] = []
        var modified: [String: Double] = [:]
        for index in LibraryFilter.tripPhotos(entries) {
            let entry = entries[index]
            guard let date = entry.created else { continue }
            let coordinate = entry.latitude.flatMap { latitude in
                entry.longitude.map { Coordinate(latitude: latitude, longitude: $0) }
            }
            photos.append(TripPhoto(id: entry.id, date: date, coordinate: coordinate))
            modified[entry.id] = entry.modified
        }
        return (photos, modified)
    }

    /// Visible still photos, including every shot of each burst.
    func burstShots() -> [PHAsset] {
        LibraryFilter.burstShots(entries).map { assets[$0] }
    }

    // MARK: - Provider

    private struct State {
        var generation = 0
        var cached: (generation: Int, snapshot: LibrarySnapshot)?
        var building: (generation: Int, task: Task<LibrarySnapshot, Never>)?
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())

    private enum Step {
        case ready(LibrarySnapshot)
        case wait(Task<LibrarySnapshot, Never>)
    }

    /// The snapshot for this activation, listing the library if there isn't one yet. Callers that
    /// arrive while it's being listed share that listing.
    static func current() async -> LibrarySnapshot {
        let step: Step = lock.withLock { state in
            if let cached = state.cached, cached.generation == state.generation { return .ready(cached.snapshot) }
            if let building = state.building, building.generation == state.generation { return .wait(building.task) }
            let generation = state.generation
            let task = Task.detached(priority: .utility) {
                let snapshot = build()
                lock.withLock { state in
                    // Without access the library looks empty, which isn't worth keeping.
                    if state.generation == generation && PhotoLibrary.isAuthorized {
                        state.cached = (generation, snapshot)
                    }
                    if state.building?.generation == generation { state.building = nil }
                }
                return snapshot
            }
            state.building = (generation, task)
            return .wait(task)
        }
        switch step {
        case .ready(let snapshot): return snapshot
        case .wait(let task): return await task.value
        }
    }

    /// The next `current()` lists the library again. A listing already under way is left to finish
    /// for those waiting on it, but isn't handed to anyone who asks after this.
    static func invalidate() {
        lock.withLock { $0.generation += 1 }
    }

    /// Lists the library and records its IDs for the coverage counts, once per snapshot.
    private static func build() -> LibrarySnapshot {
        let started = Date()
        var entries: [LibraryEntry] = []
        var assets: [PHAsset] = []
        if PhotoLibrary.isAuthorized {
            let imported = BackupStore.shared.importedAssetIDs()
            PhotoLibrary.fetchAllAssets().enumerateObjects { asset, _, _ in
                guard !imported.contains(asset.localIdentifier) else { return }
                entries.append(entry(for: asset))
                assets.append(asset)
            }
        }
        BackupStore.shared.setLibraryAssets(entries.map(\.id))
        let seconds = Date().timeIntervalSince(started)
        Log.library.info("Listed \(entries.count) of the library's assets in \(seconds, format: .fixed(precision: 2)) s")
        return LibrarySnapshot(entries: entries, assets: assets)
    }

    private static func entry(for asset: PHAsset) -> LibraryEntry {
        let kind: LibraryEntry.Kind = switch asset.mediaType {
        case .image: .image
        case .video: .video
        default: .other
        }
        let coordinate = asset.location?.coordinate
        return LibraryEntry(
            id: asset.localIdentifier, kind: kind, created: asset.creationDate,
            modified: asset.modificationDate?.timeIntervalSince1970, isHidden: asset.isHidden,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            isExtraBurstShot: asset.burstIdentifier != nil && !asset.representsBurst,
            latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }
}
