import XCTest
@testable import TripKit

final class DuplicateGrouperTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A unit-length feature print along one axis, tilted toward the next by `tilt`. Prints that
    /// share an axis are close; different axes are √2 apart.
    private func featurePrint(_ axis: Int, tilt: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[axis % 8] = 1
        v[(axis + 1) % 8] = tilt
        let length = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return v.map { $0 / length }
    }

    private func photo(_ id: String, at seconds: TimeInterval? = 0, look: Int = 0, tilt: Float = 0,
                       hash: UInt64? = nil, size: Int = 1000, burst: String? = nil,
                       aesthetics: Float = 0.3, sharpness: Double = 100, faceQuality: Float? = nil,
                       favorite: Bool = false, edited: Bool = false) -> DuplicateCandidate {
        // Each photo gets its own hash unless the test says otherwise, spread far apart in bits.
        let ownHash = hash ?? (UInt64(id.hashValueStable) &* 0x9E37_79B9_7F4A_7C15)
        return DuplicateCandidate(id: id, createdAt: seconds.map { t0.addingTimeInterval($0) },
                                  isFavorite: favorite, isEdited: edited, burstID: burst,
                                  pixelWidth: size, pixelHeight: size, dHash: ownHash,
                                  featurePrint: featurePrint(look, tilt: tilt), aesthetics: aesthetics,
                                  faceQuality: faceQuality, sharpness: sharpness)
    }

    private func ids(_ groups: [DuplicateGroup]) -> [[String]] { groups.map(\.assetIDs) }

    func testNothingToGroup() {
        XCTAssertEqual(ids(DuplicateGrouper.groups([])), [])
        XCTAssertEqual(ids(DuplicateGrouper.groups([photo("a")])), [])
    }

    func testSimilarShotsCloseInTimeGroup() {
        let groups = DuplicateGrouper.groups([photo("a", at: 0), photo("b", at: 10)])
        XCTAssertEqual(Set(ids(groups)[0]), ["a", "b"])
        XCTAssertEqual(groups.count, 1)
    }

    func testDifferentLooksStaySeparate() {
        XCTAssertEqual(ids(DuplicateGrouper.groups([photo("a", at: 0, look: 0), photo("b", at: 10, look: 3)])), [])
    }

    func testSimilarShotsFarApartInTimeStaySeparate() {
        XCTAssertEqual(ids(DuplicateGrouper.groups([photo("a", at: 0), photo("b", at: 500)])), [])
    }

    func testWindowIsMeasuredFromTheNewestMemberSoASlowSequenceChains() {
        // 100 s apart each: a-b and b-c are within the 120 s window, a-c is not.
        let groups = DuplicateGrouper.groups([photo("a", at: 0), photo("b", at: 100), photo("c", at: 200)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(ids(groups)[0]), ["a", "b", "c"])
    }

    func testFeatureDistanceThreshold() {
        // Tilt 0.3 puts the prints about 0.29 apart.
        let a = photo("a", at: 0), b = photo("b", at: 5, tilt: 0.3)
        var options = DuplicateGrouper.Options()
        options.maxFeatureDistance = 0.45
        XCTAssertEqual(DuplicateGrouper.groups([a, b], options: options).count, 1)
        options.maxFeatureDistance = 0.2
        XCTAssertEqual(DuplicateGrouper.groups([a, b], options: options).count, 0)
    }

    func testSameBurstGroupsRegardlessOfLook() {
        let groups = DuplicateGrouper.groups([photo("a", at: 0, look: 0, burst: "B"), photo("b", at: 1, look: 4, burst: "B")])
        XCTAssertEqual(groups.count, 1)
    }

    func testNearlyIdenticalHashGroupsRegardlessOfLook() {
        let groups = DuplicateGrouper.groups([photo("a", at: 0, look: 0, hash: 0b1111), photo("b", at: 1, look: 4, hash: 0b1100)])
        XCTAssertEqual(groups.count, 1)
        let far = DuplicateGrouper.groups([photo("a", at: 0, look: 0, hash: 0), photo("b", at: 1, look: 4, hash: 0b11111)])
        XCTAssertEqual(far.count, 0)
    }

    func testPhotoMustResembleEveryMemberToJoin() {
        // b is near a, c is near b but not a: c doesn't join a and b's cluster.
        let a = photo("a", at: 0, look: 0)
        let b = photo("b", at: 10, look: 0, tilt: 0.35)
        let c = photo("c", at: 20, look: 0, tilt: 0.7)
        let groups = DuplicateGrouper.groups([a, b, c])
        XCTAssertEqual(groups.map { Set($0.assetIDs) }, [["a", "b"]])
    }

    func testJoinsTheClusterItIsMostSimilarTo() {
        // x and y are far apart (different looks) and both open; z resembles y more.
        let x = photo("x", at: 0, look: 0)
        let y = photo("y", at: 5, look: 4)
        let z = photo("z", at: 10, look: 4, tilt: 0.1)
        let groups = DuplicateGrouper.groups([x, y, z])
        XCTAssertEqual(groups.map { Set($0.assetIDs) }, [["y", "z"]])
    }

    func testCopiesFarApartMergeWhenHashSizeAndLookMatch() {
        let a = photo("a", at: 0, hash: 7)
        let b = photo("b", at: 100_000, hash: 7)
        XCTAssertEqual(DuplicateGrouper.groups([a, b]).map { Set($0.assetIDs) }, [["a", "b"]])
    }

    func testCopiesWithDifferentSizeOrLookDoNotMerge() {
        XCTAssertEqual(DuplicateGrouper.groups([photo("a", at: 0, hash: 7), photo("b", at: 100_000, hash: 7, size: 999)]).count, 0)
        XCTAssertEqual(DuplicateGrouper.groups([photo("a", at: 0, hash: 7), photo("b", at: 100_000, look: 3, hash: 7)]).count, 0)
    }

    func testCopyMergeUsesATighterFeatureThirdOfTheLimit() {
        // About 0.29 apart: within 0.45 but beyond 0.15.
        let a = photo("a", at: 0, hash: 7), b = photo("b", at: 100_000, tilt: 0.3, hash: 7)
        XCTAssertEqual(DuplicateGrouper.groups([a, b]).count, 0)
    }

    func testPhotosWithoutDatesAreOnlyGroupedAsCopies() {
        let groups = DuplicateGrouper.groups([photo("a", at: nil, hash: 9), photo("b", at: nil, hash: 9), photo("c", at: nil)])
        XCTAssertEqual(groups.map { Set($0.assetIDs) }, [["a", "b"]])
    }

    func testGroupsAreNewestFirst() {
        let groups = DuplicateGrouper.groups([
            photo("old1", at: 0, look: 0), photo("old2", at: 5, look: 0),
            photo("new1", at: 10_000, look: 3), photo("new2", at: 10_005, look: 3),
            photo("mid1", at: 5_000, look: 5), photo("mid2", at: 5_005, look: 5),
        ])
        XCTAssertEqual(groups.map { Set($0.assetIDs) }, [["new1", "new2"], ["mid1", "mid2"], ["old1", "old2"]])
    }

    func testRankingFavouriteThenScore() {
        let plain = photo("plain", at: 0, aesthetics: 0.9, sharpness: 100)
        let blurry = photo("blurry", at: 1, aesthetics: 0.9, sharpness: 10)
        let faces = photo("faces", at: 2, aesthetics: 0.5, sharpness: 100, faceQuality: 0.9)
        let fave = photo("fave", at: 3, aesthetics: -0.5, sharpness: 1, favorite: true)
        let edited = photo("edited", at: 4, aesthetics: 0.75, sharpness: 100, edited: true)
        let ranked = DuplicateGrouper.rank([blurry, plain, faces, fave, edited]).map(\.id)
        // Scores: edited 1.35 beats faces 1.35 by rounding, then plain 1.3 and blurry 1.0.
        XCTAssertEqual(ranked, ["fave", "edited", "faces", "plain", "blurry"])
    }

    func testGroupsAreRankedBestFirst() {
        let groups = DuplicateGrouper.groups([photo("a", at: 0, aesthetics: 0.1), photo("b", at: 5, aesthetics: 0.8),
                                              photo("c", at: 9, aesthetics: 0.4)])
        XCTAssertEqual(ids(groups), [["b", "c", "a"]])
        XCTAssertEqual(groups[0].best, "b")
    }

    func testEachDistanceIsComputedOnce() {
        var photos = (0..<40).map { i in
            photo("q\(i)", at: Double(i) * 15, look: i / 10, tilt: Float(i % 4) * 0.05)
        }
        // Copies of each other far apart in time, so the merge step compares them too.
        photos += [photo("c1", at: 90_000, look: 2, hash: 5), photo("c2", at: 95_000, look: 2, hash: 5),
                   photo("c3", at: 99_000, look: 2, hash: 5)]
        // Two clusters that don't resemble each other, which a later photo resembles both of.
        photos += [photo("x1", at: 200_000, look: 6), photo("x2", at: 200_005, look: 6, tilt: 0.8),
                   photo("x3", at: 200_010, look: 6, tilt: 0.4)]
        var seen: [Set<String>: Int] = [:]
        let counted = DuplicateGrouper.groups(photos) { a, b in
            seen[[a.id, b.id], default: 0] += 1
            return FeaturePrint.distance(a.featurePrint, b.featurePrint)
        }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen.values.max(), 1)
        XCTAssertEqual(ids(counted), ids(DuplicateGrouper.groups(photos)))
    }

    func testStopsEarlyWhenCancelled() async {
        let photos = (0..<50).map { photo("c\($0)", at: Double($0), look: $0) }
        let calls = await Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            var calls = 0
            _ = DuplicateGrouper.groups(photos) { a, b in calls += 1; return FeaturePrint.distance(a.featurePrint, b.featurePrint) }
            return calls
        }.value
        XCTAssertEqual(calls, 0)
    }

    /// A fixed mixed set, pinned so refactors of the grouper can't change what it finds.
    func testPinnedLargeFixture() {
        var photos: [DuplicateCandidate] = []
        for i in 0..<60 {
            // Eight scenes; shots of one scene come in runs of three, 20 s apart, runs 1000 s apart.
            let scene = i / 3 % 8
            photos.append(photo("p\(i)", at: Double(i / 3) * 1000 + Double(i % 3) * 20, look: scene,
                                tilt: Float(i % 3) * 0.12, aesthetics: Float(i % 7) / 10, sharpness: Double(10 + i % 5)))
        }
        // A copy of p0 imported much later.
        photos.append(photo("copy", at: 90_000, look: 0, hash: photos[0].dHash, size: 1000))
        let groups = DuplicateGrouper.groups(photos)
        let expected: [[String]] = [["copy", "p2", "p1", "p0"], ["p59", "p58", "p57"], ["p54", "p55", "p56"], ["p53", "p52", "p51"], ["p48", "p49", "p50"], ["p47", "p46", "p45"], ["p44", "p43", "p42"], ["p41", "p39", "p40"], ["p38", "p37", "p36"], ["p34", "p33", "p35"], ["p32", "p31", "p30"], ["p27", "p29", "p28"], ["p26", "p24", "p25"], ["p23", "p22", "p21"], ["p19", "p20", "p18"], ["p17", "p16", "p15"], ["p13", "p12", "p14"], ["p11", "p9", "p10"], ["p6", "p8", "p7"], ["p4", "p5", "p3"]]
        XCTAssertEqual(ids(groups), expected)
    }
}

private extension String {
    /// A hash that doesn't change between runs (`hashValue` does).
    var hashValueStable: UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return h
    }
}
