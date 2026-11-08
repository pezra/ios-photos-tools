import XCTest
@testable import SyncKit

final class SameFileTests: XCTestCase {
    func testusameSizeIsTheSameFile() {
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: 100, storedSizes: [100]), .same)
    }

    func testudifferentSizeIsADifferentPicture() {
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: 100, storedSizes: [99]), .different)
    }

    func testuunknownPhotoSizeIsComparedInFull() {
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: nil, storedSizes: [100]), .compare)
    }

    func testunothingStoredIsComparedInFull() {
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: 100, storedSizes: []), .compare)
    }

    func testueditWithTheSameSizeIsStillComparedInFull() {
        XCTAssertEqual(SameFile.decide(isEdit: true, photoSize: 100, storedSizes: [100]), .compare)
        XCTAssertEqual(SameFile.decide(isEdit: true, photoSize: 100, storedSizes: [99]), .compare)
    }

    func testuallCopiesMustMatch() {
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: 100, storedSizes: [100, 100]), .same)
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: 100, storedSizes: [100, 101]), .different)
        XCTAssertEqual(SameFile.decide(isEdit: false, photoSize: 100, storedSizes: [101, 100]), .different)
    }
}
