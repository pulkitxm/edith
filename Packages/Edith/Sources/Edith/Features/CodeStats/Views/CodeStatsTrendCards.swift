import Charts
import EdithKit
import SwiftUI

enum CodeStatsTrendMetric: String, CaseIterable, Identifiable {
    case lines = "Lines"
    case commits = "Commits"

    var id: String { rawValue }
}

struct CodeStatsTrendCard: View {
    let projection: CodeStatsProjection
    let dark: Bool
    @State private var metric = CodeStatsTrendMetric.lines

    private var unit: Calendar.Component {
        projection.trendGranularity == .monthly ? .month : .weekOfYear
    }

    private var note: String {
        let period = projection.trendGranularity == .monthly ? "Monthly" : "Weekly"
        return period + " bars with a rolling average"
    }

    var body: some View {
        SkinCard(title: "Output over time", note: note, dark: dark) {
            Picker("Metric", selection: $metric) {
                ForEach(CodeStatsTrendMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Chart(projection.trend) { point in
                BarMark(
                    x: .value("Period", point.date, unit: unit),
                    y: .value(metric.rawValue, value(point))
                )
                .foregroundStyle(DashSkin.accent(dark).opacity(0.55))
                .cornerRadius(2)
                LineMark(
                    x: .value("Period", point.date, unit: unit),
                    y: .value("Average", average(point))
                )
                .foregroundStyle(DashPalette.slate(dark))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(2)))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(CodeStatsNumberFormat.compact(Int(number.rounded())))
                                .font(.system(size: UIScale.pt(9)))
                        }
                    }
                }
            }
            .frame(height: UIScale.pt(220))
        }
    }

    private func value(_ point: CodeStatsTrendPoint) -> Int {
        metric == .lines ? point.lines : point.commits
    }

    private func average(_ point: CodeStatsTrendPoint) -> Double {
        metric == .lines ? point.rollingLines : point.rollingCommits
    }
}

struct CodeStatsRepositoryCards: View {
    let projection: CodeStatsProjection
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            SkinCard(title: "Commits per repository", note: "Top 10", dark: dark) {
                Chart(projection.repositoryBars, id: \.repository) { summary in
                    BarMark(
                        x: .value("Commits", summary.commits),
                        y: .value("Repository", summary.repository)
                    )
                    .foregroundStyle(DashSkin.accent(dark).opacity(0.8))
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(CodeStatsNumberFormat.grouped(summary.commits))
                            .font(.system(size: UIScale.pt(10)))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().font(.system(size: UIScale.pt(10.5)))
                    }
                }
                .frame(
                    height: UIScale.pt(CGFloat(max(projection.repositoryBars.count, 1)) * 26 + 24))
            }
            CodeStatsStackedCard(
                title: "Top repositories by month", note: "Commits",
                points: projection.repositoryMonthly,
                series: projection.repositorySeries, percent: false, dark: dark)
            CodeStatsRepositoryTable(rows: projection.repositoryRows, dark: dark)
        }
    }
}

struct CodeStatsStackedCard: View {
    let title: String
    let note: String
    let points: [CodeStatsStackPoint]
    let series: [String]
    let percent: Bool
    let dark: Bool

    private var colors: [Color] {
        series.indices.map { DashPalette.categorical($0, dark: dark) }
    }

    var body: some View {
        SkinCard(title: title, note: note, dark: dark) {
            Chart(points) { point in
                if percent {
                    AreaMark(
                        x: .value("Month", point.date, unit: .month),
                        y: .value("Share", point.value), stacking: .standard
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
                } else {
                    BarMark(
                        x: .value("Month", point.date, unit: .month),
                        y: .value("Commits", point.value)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                }
            }
            .chartForegroundStyleScale(domain: series, range: colors)
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(
                                percent
                                    ? CodeStatsNumberFormat.percent(number * 100)
                                    : CodeStatsNumberFormat.compact(Int(number.rounded()))
                            )
                            .font(.system(size: UIScale.pt(9)))
                        }
                    }
                }
            }
            .frame(height: UIScale.pt(200))
            AdaptiveChartLegend(
                items: zip(series, colors).map {
                    ChartLegendItem(id: $0.0, label: $0.0, color: $0.1)
                })
        }
    }
}

private struct CodeStatsRepositoryTable: View {
    let rows: [CodeStatsRepositorySort: [CodeStatsRepositorySummary]]
    let dark: Bool
    @State private var sort = CodeStatsRepositorySort.commits
    @State private var expanded = false

    private static let collapsedCount = 12

    var body: some View {
        let sorted = rows[sort] ?? []
        SkinCard(
            title: "Repositories",
            note: CodeStatsNumberFormat.grouped(sorted.count) + " with your commits", dark: dark
        ) {
            Grid(
                alignment: .leading, horizontalSpacing: UIScale.pt(14),
                verticalSpacing: UIScale.pt(7)
            ) {
                GridRow {
                    Text("Repository").gridColumnAlignment(.leading)
                    header(.commits)
                    header(.lines)
                    Text("Language")
                    header(.lastActive)
                }
                .font(DashSkin.mono(10))
                .foregroundStyle(DashSkin.inkFaint(dark))
                Divider()
                ForEach(
                    sorted.prefix(expanded ? sorted.count : Self.collapsedCount), id: \.repository
                ) { row in
                    GridRow {
                        Text(row.repository)
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(CodeStatsNumberFormat.grouped(row.commits)).gridColumnAlignment(
                            .trailing)
                        Text(CodeStatsNumberFormat.compact(row.counts.authored))
                            .gridColumnAlignment(.trailing)
                        Text(row.topLanguage ?? "-")
                        Text(row.lastDay)
                    }
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .monospacedDigit()
                }
            }
            if sorted.count > Self.collapsedCount {
                Button(expanded ? "Show fewer" : "Show all \(sorted.count)") { expanded.toggle() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func header(_ column: CodeStatsRepositorySort) -> some View {
        Button {
            sort = column
        } label: {
            HStack(spacing: UIScale.pt(3)) {
                Text(column.title.uppercased())
                if sort == column { Image(systemName: "chevron.down") }
            }
        }
        .buttonStyle(.edith(.borderless))
        .foregroundStyle(sort == column ? DashSkin.ink(dark) : DashSkin.inkFaint(dark))
        .accessibilityLabel("Sort by \(column.title)")
    }
}
