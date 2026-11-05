import XCTest
@testable import SyncKit

final class BackupNamingTests: XCTestCase {
    private let livePhoto = [
        BackupFile(originalFilename: "IMG_1234.HEIC", isEdit: false),
        BackupFile(originalFilename: "IMG_1234.MOV", isEdit: false),
        BackupFile(originalFilename: "FullSizeRender.jpg", isEdit: true),
    ]

    private func resolve(
        _ files: [BackupFile],
        occupied: Set<String>,
        identical: Set<String> = []
    ) async throws -> [String] {
        try await BackupNaming.resolve(
            files: files,
            folder: "2026",
            isOccupied: { occupied.contains(LibraryPath.normalized($0)) },
            isIdentical: { _, path in identical.contains(LibraryPath.normalized(path)) }
        )
    }

    func testFolder() {
        XCTAssertEqual(BackupNaming.folder(year: 2026), "2026")
        XCTAssertEqual(BackupNaming.folder(year: nil), "undated")
    }

    func testEditIsNamedAfterOriginal() {
        XCTAssertEqual(BackupNaming.paths(for: livePhoto, folder: "2026", suffix: 0),
                       ["2026/IMG_1234.HEIC", "2026/IMG_1234.MOV", "2026/IMG_1234-edited.jpg"])
    }

    func testEditWithoutOriginalKeepsOwnStem() {
        let files = [BackupFile(originalFilename: "FullSizeRender.mov", isEdit: true)]
        XCTAssertEqual(BackupNaming.paths(for: files, folder: "2026", suffix: 0), ["2026/FullSizeRender-edited.mov"])
    }

    func testSuffixMatchesLibraryStyleAndIsShared() {
        XCTAssertEqual(BackupNaming.paths(for: livePhoto, folder: "2026", suffix: 1),
                       ["2026/IMG_1234 (1).HEIC", "2026/IMG_1234 (1).MOV", "2026/IMG_1234 (1)-edited.jpg"])
    }

    func testDuplicateNamesWithinAPhotoStayDistinct() {
        let files = [BackupFile(originalFilename: "A.jpg", isEdit: false), BackupFile(originalFilename: "a.JPG", isEdit: false)]
        XCTAssertEqual(BackupNaming.paths(for: files, folder: "2026", suffix: 0), ["2026/A.jpg", "2026/a-2.JPG"])
    }

    func testNamesAreSafeOnTheDrive() {
        let files = [BackupFile(originalFilename: "a/b:c?.jpg", isEdit: false), BackupFile(originalFilename: ".hidden.jpg", isEdit: false)]
        XCTAssertEqual(BackupNaming.paths(for: files, folder: "2026", suffix: 0), ["2026/a_b_c_.jpg", "2026/_hidden.jpg"])
    }

    func testFreeNameIsUsed() async throws {
        let paths = try await resolve(livePhoto, occupied: [])
        XCTAssertEqual(paths[0], "2026/IMG_1234.HEIC")
    }

    func testDifferentFileIsNeverOverwritten() async throws {
        let paths = try await resolve(livePhoto, occupied: ["2026/img_1234.heic"])
        XCTAssertEqual(paths, ["2026/IMG_1234 (1).HEIC", "2026/IMG_1234 (1).MOV", "2026/IMG_1234 (1)-edited.jpg"])
    }

    func testCollisionOnOneFileMovesWholePhoto() async throws {
        let paths = try await resolve(livePhoto, occupied: ["2026/img_1234.mov"])
        XCTAssertEqual(paths[0], "2026/IMG_1234 (1).HEIC")
    }

    func testCaseOnlyDifferenceCollides() async throws {
        let files = [BackupFile(originalFilename: "img_1234.heic", isEdit: false)]
        let paths = try await resolve(files, occupied: [LibraryPath.normalized("2026/IMG_1234.HEIC")])
        XCTAssertEqual(paths, ["2026/img_1234 (1).heic"])
    }

    func testIdenticalFileIsAdopted() async throws {
        let paths = try await resolve(livePhoto, occupied: ["2026/img_1234.heic"], identical: ["2026/img_1234.heic"])
        XCTAssertEqual(paths[0], "2026/IMG_1234.HEIC")
    }

    func testEarlierCopyIsFoundAtALaterSuffix() async throws {
        let occupied: Set<String> = ["2026/img_1234.heic", "2026/img_1234 (1).heic", "2026/img_1234 (2).heic"]
        let paths = try await resolve(livePhoto, occupied: occupied, identical: ["2026/img_1234 (2).heic"])
        XCTAssertEqual(paths[0], "2026/IMG_1234 (2).HEIC")
    }

    func testAdoptingOwnsTheEditPath() async throws {
        let occupied: Set<String> = ["2026/img_1234.heic", "2026/img_1234-edited.jpg"]
        let paths = try await resolve(livePhoto, occupied: occupied, identical: ["2026/img_1234.heic"])
        XCTAssertEqual(paths[2], "2026/IMG_1234-edited.jpg")
    }

    func testSomeoneElsesEditPathCollides() async throws {
        let paths = try await resolve(livePhoto, occupied: ["2026/img_1234-edited.jpg"])
        XCTAssertEqual(paths[2], "2026/IMG_1234 (1)-edited.jpg")
    }

    func testEditPathIsKeptWhenFree() {
        XCTAssertEqual(BackupNaming.editPath("2026/IMG_1-edited.jpg", isTaken: { _ in false }), "2026/IMG_1-edited.jpg")
    }

    func testEditPathMovesPastOtherFiles() {
        let taken: Set<String> = ["2026/IMG_1-edited.jpg", "2026/IMG_1-edited-2.jpg"]
        XCTAssertEqual(BackupNaming.editPath("2026/IMG_1-edited.jpg", isTaken: taken.contains), "2026/IMG_1-edited-3.jpg")
    }

    func testComparisonErrorsPropagate() async {
        struct Unreachable: Error {}
        do {
            _ = try await BackupNaming.resolve(files: livePhoto, folder: "2026", isOccupied: { _ in true }, isIdentical: { _, _ in throw Unreachable() })
            XCTFail("Expected an error, since guessing could overwrite a picture")
        } catch {
            XCTAssertTrue(error is Unreachable)
        }
    }

    private let heic = BackupFile(originalFilename: "IMG_1.HEIC", isEdit: false)
    private let mov = BackupFile(originalFilename: "IMG_1.MOV", isEdit: false)
    private let render = BackupFile(originalFilename: "FullSizeRender.jpg", isEdit: true)

    func testNewFileJoinsAnEditThatMoved() {
        let result = BackupNaming.extending(["2026/IMG_1.HEIC", "2026/IMG_1-edited-2.jpg", nil], files: [heic, render, mov], folder: "2026")
        XCTAssertEqual(result, ["2026/IMG_1.HEIC", "2026/IMG_1-edited-2.jpg", "2026/IMG_1.MOV"])
    }

    func testNewEditTakesTheSuffixOfTheOriginals() {
        let result = BackupNaming.extending(["2026/IMG_1 (1).HEIC", nil], files: [heic, render], folder: "2026")
        XCTAssertEqual(result, ["2026/IMG_1 (1).HEIC", "2026/IMG_1 (1)-edited.jpg"])
    }

    func testExtendingKeepsTheSpellingAlreadyThere() {
        let result = BackupNaming.extending(["2026/img_1.heic", nil], files: [heic, mov], folder: "2026")
        XCTAssertEqual(result, ["2026/img_1.heic", "2026/IMG_1.MOV"])
    }

    func testOriginalsThatDontShareASuffixCantBeExtended() {
        XCTAssertNil(BackupNaming.extending(["2026/IMG_1.HEIC", "2026/IMG_1 (1).MOV", nil], files: [heic, mov, render], folder: "2026"))
    }

    func testOriginalWithSomeOtherNameCantBeExtended() {
        XCTAssertNil(BackupNaming.extending(["2026/other.HEIC", nil], files: [heic, mov], folder: "2026"))
    }

    func testOnlyAnEditThereIsNotEnoughToGoOn() {
        XCTAssertNil(BackupNaming.extending([nil, "2026/IMG_1-edited.jpg"], files: [heic, render], folder: "2026"))
    }

    func testNewFileCantLandOnAMovedOne() {
        let second = BackupFile(originalFilename: "Other.jpg", isEdit: true)
        XCTAssertNil(BackupNaming.extending(["2026/IMG_1.HEIC", "2026/IMG_1-edited-2.jpg", nil], files: [heic, render, second], folder: "2026"))
    }
}
