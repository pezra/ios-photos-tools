import Foundation

/// Lists the drive into the store, saving as it goes, so a listing cut short (by iOS ending the
/// task, or the drive being unplugged) carries on from there next time instead of starting over.
/// A big drive takes minutes to list, mostly in reading each file's details.
public struct DriveListing {
    public enum Failure: Error, LocalizedError {
        case couldNotSave

        public var errorDescription: String? {
            "Couldn't save the record of what's in storage. This phone may be out of space."
        }
    }

    /// How far a listing has got. Folders are listed one at a time, each in name order, so the
    /// place in one stays put between passes.
    private struct State: Codable {
        /// Folders still to list, the one being listed first. "" is the top.
        var pending = [""]
        /// Every folder found, so a finished listing can forget files in the others.
        var folders = [""]
        /// The last name saved in the first pending folder, if it's part way through. A name rather
        /// than a count, so files coming and going behind it don't move the place.
        var after: String?
        var found = 0
    }

    private let store: BackupStore
    private let root: URL
    private let key: String
    private let batchSize: Int
    /// Progress is reported this often, more often than it's saved, so a continued task's progress
    /// keeps moving even where reading each file's details is slow.
    private let reportEvery: Int

    /// `key` names where the listing keeps its place in the store.
    public init(store: BackupStore, root: URL, key: String, batchSize: Int = 500, reportEvery: Int = 25) {
        self.store = store
        self.root = root
        self.key = key
        self.batchSize = batchSize
        self.reportEvery = reportEvery
    }

    /// Lists the drive, unless a listing finished within `freshFor` seconds. `progress` is told how
    /// many files have been found, counting those found by passes that were cut short.
    public func run(freshFor: TimeInterval, progress: ((Int) async -> Void)? = nil) async throws {
        let finishedKey = "\(key)-finished"
        let now = Date().timeIntervalSince1970
        if let finished = store.meta(finishedKey).flatMap(Double.init), now - finished < freshFor { return }

        let fm = FileManager.default
        var state = store.meta(key).flatMap { try? JSONDecoder().decode(State.self, from: Data($0.utf8)) } ?? State()
        func saveState() {
            if let data = try? JSONEncoder().encode(state) { store.setMeta(key, String(decoding: data, as: UTF8.self)) }
        }

        while let folder = state.pending.first {
            let dir = (root.path as NSString).appendingPathComponent(folder)
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
                try checkReachable()
                // Gone since it was found.
                state.pending.removeFirst()
                state.folders.removeAll { $0 == folder }
                state.after = nil
                saveState()
                continue
            }
            var batch: [InventoryEntry] = []
            var subfolders: [String] = []
            var replacing = state.after == nil
            func save(after: String?) throws {
                guard store.addInventory(source: .drive, entries: batch, replacingFolder: replacing ? folder : nil) else {
                    throw Failure.couldNotSave
                }
                state.found += batch.count
                state.pending += subfolders
                state.folders += subfolders
                state.after = after
                saveState()
                batch = []
                subfolders = []
                replacing = false
            }

            let after = state.after
            let sorted = names.filter { name in !name.hasPrefix(".") && after.map { name > $0 } ?? true }.sorted()
            for (index, name) in sorted.enumerated() {
                let path = folder.isEmpty ? name : "\(folder)/\(name)"
                if let attributes = try? fm.attributesOfItem(atPath: (root.path as NSString).appendingPathComponent(path)) {
                    switch attributes[.type] as? FileAttributeType {
                    case .typeDirectory:
                        subfolders.append(path)
                    case .typeRegular:
                        if LibraryPath.isLibraryContent(path), let size = attributes[.size] as? NSNumber {
                            batch.append(InventoryEntry(source: .drive, path: path, size: size.int64Value))
                        }
                    default:
                        break
                    }
                }
                if (index + 1) % batchSize == 0 {
                    // Details that couldn't be read may mean the drive's gone, not the file.
                    try checkReachable()
                    try save(after: name)
                    await progress?(state.found)
                    try Task.checkCancellation()
                } else if (index + 1) % reportEvery == 0 {
                    await progress?(state.found + batch.count)
                }
            }
            try checkReachable()
            try save(after: nil)
            state.pending.removeFirst()
            saveState()
            await progress?(state.found)
        }

        guard store.keepInventory(source: .drive, onlyInFolders: Set(state.folders)) else { throw Failure.couldNotSave }
        store.setMeta(key, "")
        store.setMeta(finishedKey, String(Date().timeIntervalSince1970))
    }

    private func checkReachable() throws {
        guard (try? root.checkResourceIsReachable()) == true else { throw CocoaError(.fileNoSuchFile) }
    }
}
