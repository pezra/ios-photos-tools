import Photos

/// Analyzes photos a few at a time, saving each result to `AnalysisStore`. Shared by the tools
/// that judge photos.
enum LibraryAnalyzer {
    /// How many photos are analyzed at once. Vision shares the Neural Engine, so more than a few
    /// doesn't help.
    private static let concurrency = 4

    /// Whether `asset` needs (re-)analyzing: never analyzed, edited since, or analyzed by an
    /// older analyzer than `minVersion`.
    static func needsAnalysis(_ asset: PHAsset, cached: PhotoAnalysis?, minVersion: Int = 1) -> Bool {
        guard let cached else { return true }
        return cached.version < minVersion || cached.modifiedAt != asset.modificationDate?.timeIntervalSince1970
    }

    /// Analyzes `assets`, calling `onResult` as each finishes. Stops early if the task is cancelled.
    @MainActor
    static func analyze(_ assets: [PHAsset], onResult: (String, Result<PhotoAnalysis, Error>) -> Void) async {
        await withTaskGroup(of: (String, Result<PhotoAnalysis, Error>).self) { group in
            var queue = assets.makeIterator()
            func addNext() {
                guard !Task.isCancelled, let asset = queue.next() else { return }
                group.addTask {
                    do { return (asset.localIdentifier, .success(try await PhotoAnalyzer.analyze(asset))) }
                    catch { return (asset.localIdentifier, .failure(error)) }
                }
            }
            for _ in 0..<concurrency { addNext() }

            while let (id, result) = await group.next() {
                if case .success(let analysis) = result { AnalysisStore.shared.save(analysis) }
                onResult(id, result)
                addNext()
            }
        }
    }
}
