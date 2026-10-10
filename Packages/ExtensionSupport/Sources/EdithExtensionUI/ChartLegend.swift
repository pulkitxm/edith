import SwiftUI

public struct ChartLegendItem: Identifiable {
    public let id: String
    public let label: String
    public let color: Color

    public init(id: String, label: String, color: Color) {
        self.id = id
        self.label = label
        self.color = color
    }
}

public struct AdaptiveChartLegend: View {
    let items: [ChartLegendItem]

    public init(items: [ChartLegendItem]) { self.items = items }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row
                .frame(maxWidth: .infinity, alignment: .center)
            ScrollView(.horizontal, showsIndicators: false) {
                row
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: UIScale.pt(18))
    }

    private var row: some View {
        HStack(spacing: UIScale.pt(12)) {
            ForEach(items) { item in
                HStack(spacing: UIScale.pt(5)) {
                    Circle()
                        .fill(item.color)
                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                    Text(item.label)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
