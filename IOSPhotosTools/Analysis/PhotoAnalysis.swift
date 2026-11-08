import Foundation

/// What the analyzer learned about one photo. Cached in `AnalysisStore`.
struct PhotoAnalysis: Sendable {
    let assetID: String
    /// The asset's modification date when analyzed; a newer one means the photo needs redoing.
    let modifiedAt: Double?
    let pixelWidth: Int
    let pixelHeight: Int
    let dHash: UInt64
    /// Vision feature print, scaled to unit length.
    let featurePrint: [Float]
    /// Vision aesthetics score, -1 (poor) to 1 (great).
    let aesthetics: Float
    /// Screenshots, receipts, documents and the like.
    let isUtility: Bool
    /// Capture quality (0–1) of the worst face in the photo, or nil if there are no faces.
    let faceQuality: Float?
    /// Number of faces found.
    let faceCount: Int
    /// Fraction of the frame (0–1) covered by the largest face.
    let faceArea: Float
    /// Fraction of the frame (0–1) covered by the largest person.
    let personArea: Float
    let sharpness: Double
    /// Which `PhotoAnalyzer.version` produced this. Older analyses lack some measurements.
    let version: Int
}
