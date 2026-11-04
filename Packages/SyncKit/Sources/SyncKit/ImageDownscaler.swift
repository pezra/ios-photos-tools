import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the low-resolution copy of a picture that's kept on the phone.
public enum ImageDownscaler {
    /// Changing these means re-importing everything to get consistent results.
    public static let maxPixelSize = 2048
    public static let heicQuality = 0.6
    /// Pictures at or below this size and resolution are kept as they are: re-encoding them would
    /// lose quality and save little.
    public static let passThroughBytes = 500_000

    public struct Result: Sendable {
        public var file: URL
        public var uniformTypeIdentifier: String
        public var fileExtension: String
        public var date: Date?
        public var latitude: Double?
        public var longitude: Double?
    }

    public enum Failure: Error, LocalizedError {
        case unreadable
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The picture couldn't be read."
            case .encodingFailed: "The low-resolution copy couldn't be made."
            }
        }
    }

    /// Whether a picture of this type, size and resolution is kept unchanged. GIFs always are,
    /// so animations survive.
    public static func shouldPassThrough(type: String, bytes: Int64, longEdge: Int) -> Bool {
        guard let type = UTType(type) else { return false }
        if type.conforms(to: .gif) { return true }
        let isPhotoFormat = type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .png)
        return isPhotoFormat && bytes <= passThroughBytes && longEdge <= maxPixelSize
    }

    /// Writes the copy of `source` into `directory` under a new name.
    public static func process(source: URL, into directory: URL) throws -> Result {
        try autoreleasepool {
            guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(image) as String?,
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { throw Failure.unreadable }

            let bytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? .max
            let longEdge = max(width, height)
            let location = location(from: properties)
            let name = UUID().uuidString

            if shouldPassThrough(type: type, bytes: bytes, longEdge: longEdge) {
                let fileExtension = source.pathExtension
                let destination = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
                try FileManager.default.copyItem(at: source, to: destination)
                return Result(file: destination, uniformTypeIdentifier: type, fileExtension: fileExtension,
                              date: date(from: properties), latitude: location?.latitude, longitude: location?.longitude)
            }

            // Never enlarges. The transform applies the orientation to the pixels.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, longEdge),
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else {
                throw Failure.unreadable
            }
            let destination = directory.appendingPathComponent(name).appendingPathExtension("HEIC")
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                throw Failure.encodingFailed
            }
            CGImageDestinationAddImage(output, thumbnail, outputProperties(from: properties) as CFDictionary)
            guard CGImageDestinationFinalize(output) else {
                try? FileManager.default.removeItem(at: destination)
                throw Failure.encodingFailed
            }
            return Result(file: destination, uniformTypeIdentifier: UTType.heic.identifier, fileExtension: "HEIC",
                          date: date(from: properties), latitude: location?.latitude, longitude: location?.longitude)
        }
    }

    /// Keeps the metadata that matters. The pixels are already upright and the dimensions are new,
    /// so those values are reset rather than copied.
    private static func outputProperties(from properties: [CFString: Any]) -> [CFString: Any] {
        var output: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: heicQuality,
            kCGImagePropertyOrientation: 1,
        ]
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { output[key] = value }
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            output[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            output[kCGImagePropertyTIFFDictionary] = tiff
        }
        return output
    }

    private static func date(from properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let value = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = ImportDate.parse(exif: value, offset: exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String) {
            return date
        }
        if let value = exif?[kCGImagePropertyExifDateTimeDigitized] as? String, let date = ImportDate.parse(exif: value) {
            return date
        }
        if let value = tiff?[kCGImagePropertyTIFFDateTime] as? String, let date = ImportDate.parse(exif: value) {
            return date
        }
        return nil
    }

    private static func location(from properties: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return (south ? -latitude : latitude, west ? -longitude : longitude)
    }
}
