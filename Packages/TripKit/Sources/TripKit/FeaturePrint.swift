import Foundation

/// Vectors describing what's in a photo, which are close together for photos that look alike.
public enum FeaturePrint {
    /// Euclidean distance between two feature prints, infinite if they can't be compared.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}
