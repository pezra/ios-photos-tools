import Photos
import TripKit

extension DuplicateCandidate {
    init(analysis: PhotoAnalysis, asset: PHAsset) {
        self.init(id: analysis.assetID, createdAt: asset.creationDate, isFavorite: asset.isFavorite,
                  isEdited: asset.hasAdjustments, burstID: asset.burstIdentifier,
                  pixelWidth: analysis.pixelWidth, pixelHeight: analysis.pixelHeight, dHash: analysis.dHash,
                  featurePrint: analysis.featurePrint, aesthetics: analysis.aesthetics,
                  faceQuality: analysis.faceQuality, sharpness: analysis.sharpness)
    }
}
