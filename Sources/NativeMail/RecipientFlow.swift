import SwiftUI

// The last child is the editable field. It uses the space after the cards
// or starts another row when its minimum comfortable width will not fit.
struct RecipientFlow: Layout {
    private let horizontalGap: CGFloat = 5
    private let verticalGap: CGFloat = 4
    private let rowHeight: CGFloat = 27

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 540
        let items = positions(width: width, subviews: subviews)
        return CGSize(width: width, height: (items.last?.point.y ?? 0) + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let items = positions(width: bounds.width, subviews: subviews)
        for (view, item) in zip(subviews, items) {
            view.place(at: CGPoint(x: bounds.minX + item.point.x, y: bounds.minY + item.point.y + rowHeight / 2),
                       anchor: .leading, proposal: ProposedViewSize(width: item.width, height: rowHeight))
        }
    }

    private func positions(width: CGFloat, subviews: Subviews) -> [(point: CGPoint, width: CGFloat)] {
        guard !subviews.isEmpty else { return [] }
        var x: CGFloat = 0
        var y: CGFloat = 0
        return subviews.indices.map { index in
            let field = index == subviews.index(before: subviews.endIndex)
            let minimum = min(width, field ? 135 : subviews[index].sizeThatFits(.unspecified).width)
            if x > 0 && x + minimum > width {
                x = 0
                y += rowHeight + verticalGap
            }
            let size = field ? width - x : minimum
            defer { x += size + horizontalGap }
            return (CGPoint(x: x, y: y), size)
        }
    }
}
