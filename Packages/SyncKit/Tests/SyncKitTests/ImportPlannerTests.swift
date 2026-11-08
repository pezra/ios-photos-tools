import XCTest
@testable import SyncKit

final class ImportPlannerTests: XCTestCase {
    private func entry(_ source: StorageSource, _ path: String) -> InventoryEntry {
        InventoryEntry(source: source, path: path, size: 1)
    }

    func testJoinsSourcesByPathDespiteSpelling() {
        let result = ImportPlanner.candidates(
            from: [entry(.drive, "2007/IMG_1.JPG"), entry(.s3, "2007/img_1.jpg")],
            handled: [], importedTags: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].onDrive)
        XCTAssertTrue(result[0].onS3)
    }

    func testKeepsTheExactSpellingInEachPlace() {
        for entries in [[entry(.drive, "2007/IMG_1.JPG"), entry(.s3, "2007/img_1.jpg")],
                        [entry(.s3, "2007/img_1.jpg"), entry(.drive, "2007/IMG_1.JPG")]] {
            let result = ImportPlanner.candidates(from: entries, handled: [], importedTags: [])
            XCTAssertEqual(result.first?.drivePath, "2007/IMG_1.JPG")
            XCTAssertEqual(result.first?.s3Path, "2007/img_1.jpg")
        }
    }

    func testSpellingOnlyInOnePlace() {
        let result = ImportPlanner.candidates(from: [entry(.s3, "2007/img_1.jpg")], handled: [], importedTags: [])
        XCTAssertNil(result.first?.drivePath)
        XCTAssertEqual(result.first?.s3Path, "2007/img_1.jpg")
        XCTAssertFalse(result[0].onDrive)
        XCTAssertTrue(result[0].onS3)
    }

    func testSameNameInDifferentFoldersStaysSeparate() {
        let result = ImportPlanner.candidates(
            from: [entry(.drive, "2007/IMG_1.JPG"), entry(.drive, "2008/IMG_1.JPG")],
            handled: [], importedTags: [])
        XCTAssertEqual(result.map(\.path), ["2008/IMG_1.JPG", "2007/IMG_1.JPG"])
    }

    func testHandledPathIsNeverImportedAgain() {
        let result = ImportPlanner.candidates(
            from: [entry(.drive, "2007/IMG_1.JPG")],
            handled: [LibraryPath.normalized("2007/IMG_1.JPG")], importedTags: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testPathWithCopyInLibraryIsSkipped() {
        let result = ImportPlanner.candidates(
            from: [entry(.s3, "2007/IMG_1.JPG")],
            handled: [], importedTags: [LibraryPath.tag(for: "2007/IMG_1.JPG")])
        XCTAssertTrue(result.isEmpty)
    }

    func testSkipsVideosHiddenFilesAndOldLayout() {
        let result = ImportPlanner.candidates(
            from: [
                entry(.drive, "2007/a.mp4"),
                entry(.drive, "2021/._IMG_0039.PNG"),
                entry(.drive, "unified-map.csv"),
                entry(.s3, "2019/08/F3057D96-632B-458A-B0B2-7C11203CA78D/IMG_1.HEIC"),
            ],
            handled: [], importedTags: [])
        XCTAssertTrue(result.isEmpty)
    }
}

final class HandledPathsTests: XCTestCase {
    func testRoundTrip() {
        let entries = [
            HandledPath(path: "2007/a.jpg", kind: .import),
            HandledPath(path: "2026/b.HEIC", kind: .backup, resourceID: "X/L0/001#1#b.HEIC", onDrive: true, inBucket: true),
        ]
        XCTAssertEqual(HandledPathsFile.decode(HandledPathsFile.encode(entries)), entries)
    }

    func testDamagedLinesAreSkipped() {
        var data = HandledPathsFile.encode([HandledPath(path: "2007/a.jpg", kind: .import)])
        data.append(Data("{\"path\":\"2007/b".utf8))
        XCTAssertEqual(HandledPathsFile.decode(data).map(\.path), ["2007/a.jpg"])
    }
}
