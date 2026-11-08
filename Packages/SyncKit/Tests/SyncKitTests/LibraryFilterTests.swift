import Foundation
import Testing
@testable import SyncKit

@Suite struct LibraryFilterTests {
    @Test func newAssetsArePending() {
        let entries = [LibraryEntry(id: "a", modified: 10), LibraryEntry(id: "b", modified: 10)]
        #expect(LibraryFilter.pending(entries, completed: ["a": 10]) == [1])
    }

    @Test func editedSinceBackupIsPending() {
        let entries = [LibraryEntry(id: "a", modified: 20), LibraryEntry(id: "b", modified: 5)]
        #expect(LibraryFilter.pending(entries, completed: ["a": 10, "b": 10]) == [0])
    }

    @Test func unknownDatesArePending() {
        let entries = [LibraryEntry(id: "a", modified: 10), LibraryEntry(id: "b", modified: nil)]
        let completed: [String: Double?] = ["a": nil, "b": 10]
        #expect(LibraryFilter.pending(entries, completed: completed) == [0, 1])
    }

    @Test func tripsSkipScreenshotsHiddenUndatedVideosAndExtraBurstShots() {
        let date = Date(timeIntervalSince1970: 1000)
        let entries = [
            LibraryEntry(id: "ok", created: date),
            LibraryEntry(id: "shot", created: date, isScreenshot: true),
            LibraryEntry(id: "hidden", created: date, isHidden: true),
            LibraryEntry(id: "undated"),
            LibraryEntry(id: "video", kind: .video, created: date),
            LibraryEntry(id: "burst2", created: date, isExtraBurstShot: true),
        ]
        #expect(LibraryFilter.tripPhotos(entries) == [0])
    }

    @Test func cleanupKeepsEveryBurstShotButNotHiddenOrVideos() {
        let entries = [
            LibraryEntry(id: "a"),
            LibraryEntry(id: "burst2", isExtraBurstShot: true),
            LibraryEntry(id: "hidden", isHidden: true),
            LibraryEntry(id: "video", kind: .video),
            LibraryEntry(id: "shot", isScreenshot: true),
        ]
        #expect(LibraryFilter.burstShots(entries) == [0, 1, 4])
    }
}
