import SwiftUI

/// Shows an illustration at a size set by its area rather than its height, so a wide bus and a tall
/// sprout look equally heavy on the page.
struct Illustration: View {
    let image: UIImage
    /// The on-screen area the subject should cover, in square points.
    var area: CGFloat
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        let size = displaySize
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)
    }

    private var displaySize: CGSize {
        Self.displaySize(aspect: max(image.size.width, 1) / max(image.size.height, 1), area: area, maxWidth: maxWidth,
                         maxHeight: maxHeight)
    }

    /// The size a picture of this shape is shown at.
    static func displaySize(aspect: CGFloat, area: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        var width = (area * aspect).squareRoot()
        var height = width / aspect
        if width > maxWidth { width = maxWidth; height = width / aspect }
        if height > maxHeight { height = maxHeight; width = height * aspect }
        return CGSize(width: width, height: height)
    }
}
