import SwiftUI
import UIKit

/// The most vivid colour in a word's picture, made readable as text on the page in light and dark mode: what words
/// and sentences light up in while they are read aloud. Nil when the picture has no vivid colour (white dominoes, say):
/// they light up grey then (`Reading`). Off the main actor, as the project's types are on it by default: asked for
/// in a detached task, it still ran on the main thread (13 ms in the simulator) until it was marked so.
nonisolated enum PictureTint {
    static func color(for data: Data) -> Color? {
        guard let image = UIImage(data: data)?.cgImage, let base = vivid(in: image) else { return nil }
        let light = readable(base, dark: false), dark = readable(base, dark: true)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private struct Sample {
        var red, green, blue, alpha, hue, saturation, brightness: CGFloat
        var vividness: CGFloat { saturation * brightness }
    }

    /// The hue that carries the most vivid colour, weighting each pixel by (saturation × brightness)² so a small
    /// bright patch beats a large dull one, then the average of that hue's most vivid pixels.
    private static func vivid(in image: CGImage) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var samples: [Sample] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[i + 3]) / 255
            guard alpha > 0.6 else { continue }
            let red = CGFloat(pixels[i]) / 255 / alpha
            let green = CGFloat(pixels[i + 1]) / 255 / alpha
            let blue = CGFloat(pixels[i + 2]) / 255 / alpha
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: red, green: green, blue: blue, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.35, brightness > 0.3 else { continue }
            samples.append(Sample(red: red, green: green, blue: blue, alpha: alpha, hue: hue,
                                  saturation: saturation, brightness: brightness))
        }
        guard samples.count >= 8 else { return nil }

        func bin(_ sample: Sample) -> Int { Int(sample.hue * 24) % 24 }
        var histogram = [CGFloat](repeating: 0, count: 24)
        for sample in samples { histogram[bin(sample)] += sample.alpha * pow(sample.vividness, 2) }
        let smoothed = (0..<24).map { histogram[$0] + 0.5 * (histogram[($0 + 23) % 24] + histogram[($0 + 1) % 24]) }
        guard let top = smoothed.indices.max(by: { smoothed[$0] < smoothed[$1] }) else { return nil }
        let nearTop = samples.filter { min(abs(bin($0) - top), 24 - abs(bin($0) - top)) <= 1 }
            .sorted { $0.vividness > $1.vividness }
        let kept = nearTop.prefix(max(1, nearTop.count * 2 / 5))
        let weight = kept.reduce(0) { $0 + $1.alpha }
        let color = UIColor(red: kept.reduce(0) { $0 + $1.red * $1.alpha } / weight,
                            green: kept.reduce(0) { $0 + $1.green * $1.alpha } / weight,
                            blue: kept.reduce(0) { $0 + $1.blue * $1.alpha } / weight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return (hue, saturation, brightness)
    }

    /// Darkened on white or lightened on black until it reads as text: 3:1 contrast, enough for a highlight that
    /// shows only while something is being read.
    private static func readable(_ color: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat), dark: Bool) -> UIColor {
        var saturation = color.saturation, brightness = color.brightness
        for _ in 0..<200 {
            let candidate = UIColor(hue: color.hue, saturation: saturation, brightness: brightness, alpha: 1)
            if contrast(candidate, dark: dark) >= 3 { return candidate }
            if dark {
                if brightness < 1 { brightness = min(1, brightness + 0.02) } else { saturation = max(0, saturation - 0.02) }
            } else {
                brightness = max(0, brightness - 0.02)
            }
        }
        return UIColor(hue: color.hue, saturation: saturation, brightness: brightness, alpha: 1)
    }

    private static func contrast(_ color: UIColor, dark: Bool) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return dark ? (luminance + 0.05) / 0.05 : 1.05 / (luminance + 0.05)
    }
}
