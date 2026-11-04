import XCTest
@testable import TripKit

final class TripPickerTests: XCTestCase {
    /// Feature prints along different axes are as far apart as unit vectors get (√2).
    private func axis(_ i: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[i % 8] = 1
        return v
    }

    private func shot(_ id: String, aesthetics: Float = 0.3, faceArea: Float = 0, personArea: Float = 0,
                      faceQuality: Float? = nil, isUtility: Bool = false, isFavorite: Bool = false,
                      look: Int = 0) -> PickCandidate {
        PickCandidate(id: id, aesthetics: aesthetics, isUtility: isUtility,
                      faceCount: faceArea > 0 ? 1 : 0, faceArea: faceArea, personArea: personArea,
                      faceQuality: faceQuality, sharpness: 100, isFavorite: isFavorite, isEdited: false,
                      featurePrint: axis(look))
    }

    func testKinds() {
        XCTAssertEqual(TripPicker.kind(shot("portrait", faceArea: 0.05)), .people)
        XCTAssertEqual(TripPicker.kind(shot("posing", faceArea: 0.003, personArea: 0.2)), .people)
        XCTAssertEqual(TripPicker.kind(shot("view")), .scene)
        XCTAssertEqual(TripPicker.kind(shot("crowd", faceArea: 0.004, personArea: 0.05)), .other)
    }

    func testPicksPersonAndSceneOverHigherScoringShots() {
        let shots = [
            shot("view1", aesthetics: 0.9, look: 1),
            shot("view2", aesthetics: 0.8, look: 2),
            shot("view3", aesthetics: 0.7, look: 3),
            shot("me", aesthetics: 0.2, faceArea: 0.05, faceQuality: 0.6, look: 4),
            shot("view4", aesthetics: 0.1, look: 5),
        ]
        XCTAssertEqual(Set(TripPicker.picks(shots)), ["view1", "me"])
    }

    func testThirdPickMustLookDifferent() {
        var shots = (0..<12).map { shot("same\($0)", aesthetics: 0.5 - Float($0) * 0.01, look: 1) }
        shots.append(shot("different", aesthetics: 0.1, look: 2))
        let picks = TripPicker.picks(shots)
        XCTAssertEqual(picks.count, 2)
        XCTAssertEqual(Set(picks), ["same0", "different"])
    }

    func testSkipsUtilityAndPoorShots() {
        let shots = [
            shot("receipt", aesthetics: 0.9, isUtility: true),
            shot("blurry", aesthetics: -0.8, look: 1),
            shot("ok", aesthetics: 0.1, look: 2),
            shot("fine", aesthetics: 0.05, look: 3),
        ]
        XCTAssertEqual(TripPicker.picks(shots), ["ok"])
    }

    func testFavouriteWins() {
        let shots = [
            shot("great", aesthetics: 0.9, look: 1),
            shot("loved", aesthetics: -0.5, isFavorite: true, look: 2),
            shot("good", aesthetics: 0.6, look: 3),
        ]
        XCTAssertEqual(TripPicker.picks(shots), ["loved"])
    }

    func testLoneMediocreShotIsSkipped() {
        XCTAssertEqual(TripPicker.picks([shot("meh", aesthetics: -0.1)]), [])
        XCTAssertEqual(TripPicker.picks([shot("nice", aesthetics: 0.4)]), ["nice"])
    }

    func testPickCount() {
        XCTAssertEqual(TripPicker.pickCount(distinctShots: 0), 0)
        XCTAssertEqual(TripPicker.pickCount(distinctShots: 3), 1)
        XCTAssertEqual(TripPicker.pickCount(distinctShots: 4), 2)
        XCTAssertEqual(TripPicker.pickCount(distinctShots: 12), 3)
    }
}
