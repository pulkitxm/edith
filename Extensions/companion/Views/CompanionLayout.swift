import EdithExtensionUI
import SwiftUI

struct WrapHStack<Content: View>: View {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        CompanionWrapLayout(spacing: spacing, lineSpacing: lineSpacing) { content() }
    }
}

struct CompanionWrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize])
        -> CGSize
    {
        let maxWidth = proposal.width ?? 300
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

struct PageGrid<Primary: View, Secondary: View, Full: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    @ViewBuilder let full: () -> Full

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            PageColumns {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    primary()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    secondary()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            full()
        }
    }
}

struct PageTabPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .font(.edithText(.body))
            .accessibilityLabel(title)
        } else {
            EdithSegmentedPicker(title, selection: $selection, options: options, label: label)
                .labelsHidden()
        }
    }
}
