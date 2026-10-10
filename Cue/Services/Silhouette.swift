import UIKit

/// A picture's subject as the typed words see it when the picture takes their place: its outer edge, as points round
/// it, and its colours, both in the unit square.
nonisolated enum Silhouette {
    struct Trace {
        var edge: [CGPoint]
        /// Points spread over the subject, in no particular order, and how much of the unit square it covers.
        var interior: [CGPoint]
        var coverage: CGFloat
        var colors: ColorGrid
    }

    /// The picture at a coarse size, for the colour under a point.
    struct ColorGrid {
        var width: Int
        var height: Int
        /// Premultiplied, 0...1.
        var cells: [SIMD4<Float>]

        /// The colour at a point of the unit square, from the nearest solid cell within a couple of cells; nil over
        /// nothing.
        func color(at point: CGPoint) -> SIMD3<Float>? {
            let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
            let y = min(max(Int(point.y * CGFloat(height)), 0), height - 1)
            var best: SIMD4<Float>?
            var bestDistance = Int.max
            for dy in -2...2 {
                for dx in -2...2 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let cell = cells[ny * width + nx]
                    let distance = dx * dx + dy * dy
                    if cell.w > 0.5, distance < bestDistance { best = cell; bestDistance = distance }
                }
            }
            guard let best else { return nil }
            return SIMD3(best.x, best.y, best.z) / best.w
        }
    }

    static func trace(_ data: Data, longestSide: Int = 64) -> Trace? {
        guard let image = UIImage(data: data) else { return nil }
        return trace(image, longestSide: longestSide)
    }

    static func trace(_ image: UIImage, longestSide: Int = 64) -> Trace? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = CGFloat(longestSide) / CGFloat(max(cgImage.width, cgImage.height))
        let w = max(Int(CGFloat(cgImage.width) * scale), 2), h = max(Int(CGFloat(cgImage.height) * scale), 2)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let cells = (0..<(w * h)).map { i in
            SIMD4(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2]), Float(pixels[i * 4 + 3])) / 255
        }
        let solid = cells.map { $0.w > 0.25 }

        // The largest connected piece of the subject.
        var label = [Int](repeating: 0, count: w * h)
        var best = 0, bestSize = 0, current = 0
        for start in 0..<(w * h) where solid[start] && label[start] == 0 {
            current += 1
            var stack = [start], size = 0
            label[start] = current
            while let p = stack.popLast() {
                size += 1
                let x = p % w, y = p / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let q = ny * w + nx
                    if solid[q], label[q] == 0 { label[q] = current; stack.append(q) }
                }
            }
            if size > bestSize { bestSize = size; best = current }
        }
        guard bestSize > 0, let startIndex = label.firstIndex(of: best) else { return nil }
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && label[y * w + x] == best }

        // Round its edge (Moore neighbours), from its topmost-leftmost pixel, having come from the west.
        let around = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        let sx = startIndex % w, sy = startIndex / w
        var cx = sx, cy = sy, bx = sx - 1, by = sy
        var points: [CGPoint] = []
        var steps = 0
        repeat {
            points.append(CGPoint(x: (CGFloat(cx) + 0.5) / CGFloat(w), y: (CGFloat(cy) + 0.5) / CGFloat(h)))
            let from = around.firstIndex { $0.0 == bx - cx && $0.1 == by - cy } ?? 0
            var moved = false
            var previous = (bx, by)
            for k in 0..<8 {
                let d = around[(from + k) % 8]
                let nx = cx + d.0, ny = cy + d.1
                if inside(nx, ny) {
                    (bx, by) = previous
                    (cx, cy) = (nx, ny)
                    moved = true
                    break
                }
                previous = (nx, ny)
            }
            guard moved else { break }
            steps += 1
        } while !(cx == sx && cy == sy) && steps < 8 * w * h
        guard points.count > 3 else { return nil }

        // Points over the subject, shuffled the same way every time, so letters gather into its whole shape.
        var cellsInside = label.indices.filter { label[$0] == best }
        var seed: UInt32 = 2_463_534_242
        for i in stride(from: cellsInside.count - 1, to: 0, by: -1) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            cellsInside.swapAt(i, Int(seed >> 8) % (i + 1))
        }
        let interior = cellsInside.prefix(160).map {
            CGPoint(x: (CGFloat($0 % w) + 0.5) / CGFloat(w), y: (CGFloat($0 / w) + 0.5) / CGFloat(h))
        }
        return Trace(edge: points, interior: interior, coverage: CGFloat(bestSize) / CGFloat(w * h),
                     colors: ColorGrid(width: w, height: h, cells: cells))
    }
}
