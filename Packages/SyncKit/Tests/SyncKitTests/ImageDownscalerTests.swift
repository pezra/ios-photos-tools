import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SyncKit

final class ImageDownscalerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Noise, so a JPEG is big enough not to be passed through.
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var generator = SystemRandomNumberGenerator()
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt32.self)
        for index in 0..<(context.bytesPerRow / 4 * height) {
            data[index] = UInt32.random(in: 0...UInt32.max, using: &generator) | 0xFF00_0000
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, name: String, type: UTType = .jpeg, properties: [CFString: Any] = [:]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func size(of url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    func testLargeImageBecomesSmallerHEIC() throws {
        let source = try write(makeImage(width: 4000, height: 3000), name: "a.jpg")
        let result = try ImageDownscaler.process(source: source, into: directory)
        XCTAssertEqual(result.fileExtension, "HEIC")
        let output = try size(of: result.file)
        XCTAssertEqual(output.width, 2048)
        XCTAssertEqual(output.height, 1536)
        XCTAssertLessThan(try XCTUnwrap(result.file.resourceValues(forKeys: [.fileSizeKey]).fileSize),
                          try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }

    func testOrientationIsAppliedToPixels() throws {
        let source = try write(makeImage(width: 4000, height: 3000), name: "a.jpg", properties: [kCGImagePropertyOrientation: 6])
        let result = try ImageDownscaler.process(source: source, into: directory)
        let output = try size(of: result.file)
        XCTAssertEqual(output.width, 1536)
        XCTAssertEqual(output.height, 2048)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(result.file as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testBigFileAtLowResolutionIsNotEnlarged() throws {
        let source = try write(makeImage(width: 1200, height: 900), name: "a.jpg", properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        XCTAssertGreaterThan(try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize), ImageDownscaler.passThroughBytes)
        let result = try ImageDownscaler.process(source: source, into: directory)
        XCTAssertEqual(result.fileExtension, "HEIC")
        XCTAssertEqual(try size(of: result.file).width, 1200)
    }

    func testSmallImageIsCopiedUnchanged() throws {
        let source = try write(makeImage(width: 100, height: 80), name: "small.jpg")
        let result = try ImageDownscaler.process(source: source, into: directory)
        XCTAssertEqual(result.fileExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: result.file), try Data(contentsOf: source))
    }

    func testGIFAlwaysPassesThrough() {
        XCTAssertTrue(ImageDownscaler.shouldPassThrough(type: UTType.gif.identifier, bytes: 50_000_000, longEdge: 5000))
    }

    func testBMPIsAlwaysConverted() {
        XCTAssertFalse(ImageDownscaler.shouldPassThrough(type: UTType.bmp.identifier, bytes: 1000, longEdge: 100))
    }

    func testMetadataSurvives() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2003:05:18 14:02:11"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 40.5, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 105.25, kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
        let source = try write(makeImage(width: 3000, height: 2000), name: "a.jpg", properties: properties)
        let result = try ImageDownscaler.process(source: source, into: directory)
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.year, from: try XCTUnwrap(result.date)), 2003)
        XCTAssertEqual(try XCTUnwrap(result.latitude), 40.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.longitude), -105.25, accuracy: 0.001)

        let output = try XCTUnwrap(CGImageSourceCreateWithURL(result.file as CFURL, nil))
        let copied = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(copied[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2003:05:18 14:02:11")
    }

    func testUnreadableFileThrows() throws {
        let source = directory.appendingPathComponent("broken.jpg")
        try Data("not a picture".utf8).write(to: source)
        XCTAssertThrowsError(try ImageDownscaler.process(source: source, into: directory))
    }
}
