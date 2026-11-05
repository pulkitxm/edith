import SwiftUI

public struct WrapHStack<Content: View>: View {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    public init(
        spacing: CGFloat = 6, lineSpacing: CGFloat = 6,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.spacing = spacing; self.lineSpacing = lineSpacing; self.content = content
    }

    public var body: some View {
        _WrapLayout(spacing: spacing, lineSpacing: lineSpacing) { content() }
    }
}

struct _WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize])
        -> CGSize
    {
        let singleLine =
            cache.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(cache.count - 1, 0))
        guard let proposed = proposal.width, proposed.isFinite else {
            return CGSize(width: singleLine, height: cache.map(\.height).max() ?? 0)
        }
        let maxWidth = proposed
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for size in cache {
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout [CGSize]
    ) -> CGFloat? {
        guard guide == .firstTextBaseline,
            let first = subviews.first, let firstSize = cache.first
        else { return nil }
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for size in cache {
            if lineWidth + size.width > bounds.width, lineWidth > 0 { break }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        let baseline = first.dimensions(in: .unspecified)[.firstTextBaseline]
        return bounds.minY + (lineHeight - firstSize.height) / 2 + baseline
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]
    ) {
        var y: CGFloat = bounds.minY
        var line: [(view: LayoutSubviews.Element, size: CGSize)] = []
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        func flushLine() {
            var x = bounds.minX
            for entry in line {
                entry.view.place(
                    at: CGPoint(x: x, y: y + (lineHeight - entry.size.height) / 2),
                    proposal: .unspecified)
                x += entry.size.width + spacing
            }
            y += lineHeight + lineSpacing
            line = []
            lineWidth = 0
            lineHeight = 0
        }

        for (index, view) in subviews.enumerated() {
            let size =
                cache.indices.contains(index) ? cache[index] : view.sizeThatFits(.unspecified)
            if lineWidth + size.width > bounds.width, !line.isEmpty {
                flushLine()
            }
            line.append((view, size))
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        flushLine()
    }
}
