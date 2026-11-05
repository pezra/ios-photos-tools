import XCTest
@testable import SyncKit

final class LibraryPathTests: XCTestCase {
    func testNormalizedIgnoresCaseAndUnicodeForm() {
        XCTAssertEqual(LibraryPath.normalized("2007/IMG_1.JPG"), LibraryPath.normalized("2007/img_1.jpg"))
        XCTAssertEqual(LibraryPath.normalized("undated/caf\u{00E9}.jpg"), LibraryPath.normalized("undated/cafe\u{0301}.jpg"))
    }

    func testKeyOmitsAnEmptyPrefix() {
        XCTAssertEqual(LibraryPath.key(prefix: "photos", path: "2007/a.jpg"), "photos/2007/a.jpg")
        XCTAssertEqual(LibraryPath.key(prefix: "", path: "2007/a.jpg"), "2007/a.jpg")
    }

    func testTagIsStableAcrossSpellingsAndDiffersByFolder() {
        XCTAssertEqual(LibraryPath.tag(for: "2007/IMG_1.JPG"), LibraryPath.tag(for: "2007/img_1.jpg"))
        XCTAssertNotEqual(LibraryPath.tag(for: "2007/IMG_1.JPG"), LibraryPath.tag(for: "2008/IMG_1.JPG"))
        XCTAssertEqual(LibraryPath.tag(for: "2007/IMG_1.JPG").count, 12)
    }

    func testTaggedFilenameRoundTrips() {
        let name = LibraryPath.taggedFilename(for: "2007/023 (2).JPG", fileExtension: "HEIC")
        XCTAssertTrue(name.hasPrefix("023 (2).ptk-"))
        XCTAssertTrue(name.hasSuffix(".HEIC"))
        XCTAssertEqual(LibraryPath.tag(inFilename: name), LibraryPath.tag(for: "2007/023 (2).JPG"))
    }

    func testTaggedFilenameFitsLimitAndKeepsTag() {
        let long = "undated/" + String(repeating: "é", count: 200) + ".jpg"
        let name = LibraryPath.taggedFilename(for: long, fileExtension: "HEIC")
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertEqual(LibraryPath.tag(inFilename: name), LibraryPath.tag(for: long))
    }

    func testOrdinaryFilenamesHaveNoTag() {
        for name in ["IMG_1234.HEIC", "FullSizeRender.jpg", "a.ptk-.jpg", "a.ptk-zzzzzzzzzzzz.jpg", "a.ptk-9f3a2c1b7d04"] {
            XCTAssertNil(LibraryPath.tag(inFilename: name), name)
        }
    }

    func testLibraryContentSkipsHiddenAndOldLayout() {
        XCTAssertTrue(LibraryPath.isLibraryContent("2007/023 (2).JPG"))
        XCTAssertTrue(LibraryPath.isLibraryContent("undated/14Mar2005/Pictures/a.jpg"))
        XCTAssertTrue(LibraryPath.isLibraryContent("2026/IMG_1.MOV"))
        XCTAssertFalse(LibraryPath.isLibraryContent("2021/._IMG_0039.PNG"))
        XCTAssertFalse(LibraryPath.isLibraryContent(".photos-tools/handled-paths.jsonl"))
        XCTAssertFalse(LibraryPath.isLibraryContent("2026/.IMG_1.HEIC.partial"))
        XCTAssertFalse(LibraryPath.isLibraryContent("2019/08/F3057D96-632B-458A-B0B2-7C11203CA78D/IMG_1.HEIC"))
    }

    func testFolderThatOnlyResemblesOldLayoutIsContent() {
        XCTAssertTrue(LibraryPath.isLibraryContent("undated/08/notauuid/IMG_1.HEIC"))
    }

    func testImportableIsImagesOnly() {
        for path in ["2007/a.JPG", "2007/a.jpeg", "2020/a.HEIC", "2007/a.png", "2007/a.gif", "2007/a.bmp", "2007/a.NEF"] {
            XCTAssertTrue(LibraryPath.isImportable(path), path)
        }
        for path in ["2007/a.mp4", "2007/a.MOV", "2007/a.avi", "removed-near-duplicates.csv", "2021/._a.jpg"] {
            XCTAssertFalse(LibraryPath.isImportable(path), path)
        }
    }

    func testUndated() {
        XCTAssertTrue(LibraryPath.isUndated("undated/x/a.jpg"))
        XCTAssertFalse(LibraryPath.isUndated("2007/undated.jpg"))
    }
}

final class ImportDateTests: XCTestCase {
    private func year(_ date: Date?) -> Int? {
        date.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    func testParsesExif() {
        XCTAssertEqual(year(ImportDate.parse(exif: "2003:05:18 14:02:11")), 2003)
    }

    func testAppliesOffset() {
        let date = ImportDate.parse(exif: "2021:01:01 00:00:00", offset: "+02:00")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2020-12-31T22:00:00Z"))
    }

    func testRejectsBlankDates() {
        XCTAssertNil(ImportDate.parse(exif: "0000:00:00 00:00:00"))
        XCTAssertNil(ImportDate.parse(exif: "    :  :     :  :  "))
        XCTAssertNil(ImportDate.parse(exif: ""))
    }

    func testFallbackUsesFolderYear() {
        XCTAssertEqual(year(ImportDate.fallback(for: "2007/a.jpg")), 2007)
        XCTAssertEqual(year(ImportDate.fallback(for: "undated/x/a.jpg")), 2000)
    }
}
