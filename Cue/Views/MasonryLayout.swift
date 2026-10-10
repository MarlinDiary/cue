import SwiftUI

/// Places each subview in the currently shortest column.
struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Containers probe with nil, zero and infinite widths; answer those with a sane width.
        let proposed = proposal.width ?? 370
        let width = proposed.isFinite && proposed > 0 ? proposed : 370
        let height = frames(for: subviews, width: width).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        let count = max(columns, 1)
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
        var heights = Array(repeating: CGFloat(0), count: count)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
    }
}
