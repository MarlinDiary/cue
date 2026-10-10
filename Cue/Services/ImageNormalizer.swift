import CoreGraphics
import UIKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes illustrations comparable: the model leaves a different amount of empty canvas around each
/// subject, so we crop to the visible pixels and add back the same small margin everywhere.
nonisolated enum ImageNormalizer {
    /// Crops a transparent PNG to its visible pixels plus `padding` (a fraction of the longest side),
    /// and scales it so the longest side is at most `maxPixel`.
    static func trimmed(_ data: Data, padding: CGFloat = 0.04, maxPixel: Int = 768) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let bounds = visibleBounds(of: image) else { return nil }

        let margin = max(bounds.width, bounds.height) * padding
        let cropped = bounds.insetBy(dx: -margin, dy: -margin)
        let scale = min(1, CGFloat(maxPixel) / max(cropped.width, cropped.height))
        let width = max(Int((cropped.width * scale).rounded()), 1)
        let height = max(Int((cropped.height * scale).rounded()), 1)

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        // Core Graphics puts the origin at the bottom left; `bounds` is measured from the top.
        let drawRect = CGRect(
            x: -cropped.minX * scale,
            y: -(CGFloat(image.height) - cropped.maxY) * scale,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        context.draw(image, in: drawRect)
        guard let result = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, result, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The rectangle (top-left origin, in pixels) holding every pixel that is not almost transparent.
    private static func visibleBounds(of image: CGImage, threshold: UInt8 = 10) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
