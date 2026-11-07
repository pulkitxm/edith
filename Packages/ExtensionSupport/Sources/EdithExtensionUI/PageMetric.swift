import SwiftUI

private struct PageMetricFillsRowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var pageMetricFillsRow: Bool {
        get { self[PageMetricFillsRowKey.self] }
        set { self[PageMetricFillsRowKey.self] = newValue }
    }
}

public struct PageMetric: View {
    let title: String
    let value: String
    var detail: String?
    var icon: EdithIcon?
    var tint: Color?
    var trend: String?
    var trendPositive = true
    var valueBlurred = false
    var detailBlurred = false
    @Environment(\.pageMetricFillsRow) private var fillsRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    public init(
        title: String, value: String, detail: String? = nil, icon: EdithIcon? = nil,
        tint: Color? = nil, trend: String? = nil, trendPositive: Bool = true,
        valueBlurred: Bool = false, detailBlurred: Bool = false
    ) {
        self.title = title; self.value = value; self.detail = detail; self.icon = icon
        self.tint = tint; self.trend = trend; self.trendPositive = trendPositive
        self.valueBlurred = valueBlurred; self.detailBlurred = detailBlurred
    }

    public var body: some View {
        PageCard(fill: fillsRow) {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.metricRowSpacing)) {
                titleRow
                valueRow
                if let detail {
                    Text(detail).font(.edithText(.subheadline)).foregroundStyle(.secondary)
                        .monospacedDigit().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                        .animation(
                            Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                            value: detail
                        )
                        .presenterBlur(detailBlurred)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleRow: some View {
        HStack(spacing: UIScale.pt(6)) {
            if let icon {
                EdithIconView(icon).foregroundStyle(tint ?? .secondary)
            }
            Text(title).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.edithText(.subheadline).weight(.medium))
        .frame(height: UIScale.pt(PageMetrics.metricTitleHeight), alignment: .leading)
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            Text(value).font(DashSkin.heading(PageMetrics.metricValueSize)).monospacedDigit()
                .foregroundStyle(DashSkin.ink(scheme == .dark))
                .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                .animation(
                    Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: value
                )
                .presenterBlur(valueBlurred)
            if let trend {
                Label(trend, edith: trendPositive ? .arrowUpRight : .arrowDownRight)
                    .labelStyle(PageMetricTrendLabelStyle())
                    .font(.edithText(.subheadline).weight(.medium))
                    .foregroundStyle(trendPositive ? .green : .red)
                    .fixedSize()
                    .help("Compared with the previous period of the same length")
            }
        }
        .frame(height: UIScale.pt(PageMetrics.metricValueHeight), alignment: .leading)
    }
}

private struct PageMetricTrendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: UIScale.pt(2)) {
            configuration.icon
            configuration.title
        }
    }
}

public struct PageMetricSkeleton: View {
    @Environment(\.pageMetricFillsRow) private var fillsRow

    public init() {}

    public var body: some View {
        PageCard(fill: fillsRow) {
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.metricRowSpacing)) {
                SkeletonBlock(width: 80, height: 10)
                    .frame(height: UIScale.pt(PageMetrics.metricTitleHeight))
                SkeletonBlock(width: 96, height: 22)
                    .frame(height: UIScale.pt(PageMetrics.metricValueHeight))
                SkeletonBlock(width: 120, height: 9).frame(height: UIScale.pt(14))
            }
        }
    }
}

public struct PageMetricGrid<Content: View>: View {
    var minimumWidth = PageMetrics.metricMinimumWidth
    var maximumColumns: Int?
    @ViewBuilder let content: () -> Content

    public init(
        minimumWidth: Double = PageMetrics.metricMinimumWidth, maximumColumns: Int? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.minimumWidth = minimumWidth
        self.maximumColumns = maximumColumns
        self.content = content
    }

    public var body: some View {
        PageMetricLayout(
            spacing: UIScale.pt(PageMetrics.cardSpacing), minimumWidth: UIScale.pt(minimumWidth),
            maximumColumns: maximumColumns
        ) {
            content()
        }
        .environment(\.pageMetricFillsRow, true)
    }
}

struct PageMetricLayout: Layout {
    let spacing: CGFloat
    let minimumWidth: CGFloat
    let maximumColumns: Int?

    func rowCounts(count: Int, width: CGFloat) -> [Int] {
        guard count > 0 else { return [] }
        let columns = PageMetrics.fittedColumns(
            count: count, width: width, minimum: minimumWidth, spacing: spacing,
            limit: maximumColumns)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        return (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
    }

    private func tileWidth(_ columns: Int, in width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    private func height(of row: ArraySlice<LayoutSubview>, tileWidth: CGFloat) -> CGFloat {
        row.map { $0.sizeThatFits(ProposedViewSize(width: tileWidth, height: nil)).height }.max()
            ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = max(1, min(subviews.count, maximumColumns ?? subviews.count))
        let width =
            proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? minimumWidth * CGFloat(count) + spacing * CGFloat(count - 1)
        var start = 0
        var total: CGFloat = 0
        let rows = rowCounts(count: subviews.count, width: width)
        for columns in rows {
            let row = Array(subviews)[start..<start + columns]
            total += height(of: row, tileWidth: tileWidth(columns, in: width))
            start += columns
        }
        return CGSize(width: width, height: total + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var start = 0
        var y = bounds.minY
        for columns in rowCounts(count: subviews.count, width: bounds.width) {
            let row = Array(subviews)[start..<start + columns]
            let width = tileWidth(columns, in: bounds.width)
            let rowHeight = height(of: row, tileWidth: width)
            for (offset, tile) in row.enumerated() {
                tile.place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(offset) * (width + spacing), y: y),
                    proposal: ProposedViewSize(width: width, height: rowHeight))
            }
            y += rowHeight + spacing
            start += columns
        }
    }
}
