import CoreGraphics
import Foundation

/// Cheap measurements computed directly from pixels.
enum ImageMetrics {
    /// 64-bit difference hash: shrink to 9×8 grey, then one bit per horizontally adjacent pair
    /// (set when the left pixel is brighter). Re-encoded or resized copies hash identically or
    /// within a bit or two.
    static func dHash(_ image: CGImage) -> UInt64? {
        guard let pixels = greyscale(image, width: 9, height: 8) else { return nil }
        var hash: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                hash <<= 1
                if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Variance of the Laplacian over a greyscale copy at most `maxSide` pixels across. Higher is
    /// sharper; only meaningful when comparing shots of the same scene.
    static func sharpness(_ image: CGImage, maxSide: Int = 512) -> Double? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(3, Int(Double(image.width) * scale))
        let height = max(3, Int(Double(image.height) * scale))
        guard let pixels = greyscale(image, width: width, height: height) else { return nil }

        var sum = 0.0
        var sumOfSquares = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let laplacian = Double(pixels[i - 1]) + Double(pixels[i + 1]) + Double(pixels[i - width])
                    + Double(pixels[i + width]) - 4 * Double(pixels[i])
                sum += laplacian
                sumOfSquares += laplacian * laplacian
            }
        }
        let count = Double((width - 2) * (height - 2))
        let mean = sum / count
        return sumOfSquares / count - mean * mean
    }

    /// `vector` scaled to unit length, so Euclidean distances fall in 0...2.
    static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    private static func greyscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
