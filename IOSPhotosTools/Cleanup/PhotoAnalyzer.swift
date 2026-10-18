import Photos
import UIKit
import Vision

/// Runs on-device models over a photo: Vision's feature print (for similarity), aesthetics
/// score and face capture quality (for picking the best shot), plus a hash and sharpness.
enum PhotoAnalyzer {
    /// Vision scales images down to a few hundred pixels anyway, so a small thumbnail is enough
    /// and much faster to load than the original.
    static let thumbnailSize = CGSize(width: 512, height: 512)

    enum AnalysisError: Error {
        case noImage
        case unsupportedFeaturePrint
    }

    static func analyze(_ asset: PHAsset) async throws -> PhotoAnalysis {
        let (image, orientation) = try await thumbnail(of: asset)

        let (featurePrint, aesthetics, faces) = try await ImageRequestHandler(image, orientation: orientation).perform(
            GenerateImageFeaturePrintRequest(),
            CalculateImageAestheticsScoresRequest(),
            DetectFaceCaptureQualityRequest()
        )
        guard let dHash = ImageMetrics.dHash(image), let sharpness = ImageMetrics.sharpness(image) else {
            throw AnalysisError.noImage
        }

        return PhotoAnalysis(assetID: asset.localIdentifier,
                             modifiedAt: asset.modificationDate?.timeIntervalSince1970,
                             pixelWidth: asset.pixelWidth,
                             pixelHeight: asset.pixelHeight,
                             dHash: dHash,
                             featurePrint: ImageMetrics.normalized(try floats(featurePrint)),
                             aesthetics: aesthetics.overallScore,
                             isUtility: aesthetics.isUtility,
                             faceQuality: faces.compactMap { $0.captureQuality?.score }.min(),
                             sharpness: sharpness)
    }

    private static func floats(_ observation: FeaturePrintObservation) throws -> [Float] {
        switch observation.elementType {
        case .float:
            return copy(observation.data, as: Float.self, count: observation.elementCount)
        case .double:
            return copy(observation.data, as: Double.self, count: observation.elementCount).map(Float.init)
        @unknown default:
            throw AnalysisError.unsupportedFeaturePrint
        }
    }

    private static func copy<T: BinaryFloatingPoint>(_ data: Data, as type: T.Type, count: Int) -> [T] {
        var values = [T](repeating: 0, count: min(count, data.count / MemoryLayout<T>.size))
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    /// The current (edited, if it has been) version, downloading from iCloud if necessary.
    private static func thumbnail(of asset: PHAsset) async throws -> (CGImage, CGImagePropertyOrientation) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFit,
                                                  options: options) { image, info in
                if let image, let cgImage = image.cgImage {
                    continuation.resume(returning: (cgImage, CGImagePropertyOrientation(image.imageOrientation)))
                } else {
                    continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? AnalysisError.noImage)
                }
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
