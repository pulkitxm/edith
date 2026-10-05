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
    @State private var cumulative = false
    @State private var hovered: Date?
    @State private var brushed: ClosedRange<Date>?
    @Environment(\.codeStatsActions) private var actions

    private var unit: Calendar.Component {
        projection.trendGranularity == .monthly ? .month : .weekOfYear
    }

    private var note: String {
        if cumulative { return "Running total since the start of the range" }
        let period = projection.trendGranularity == .monthly ? "Monthly" : "Weekly"
        return period + " bars, drag to zoom, click a bar to open it"
    }

    private var selected: CodeStatsTrendPoint? {
        guard let hovered else { return nil }
        return projection.trend.min {
            abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered))
        }
    }

    var body: some View {
        SkinCard(title: "Output over time", note: note, dark: dark) {
            HStack(spacing: UIScale.pt(10)) {
                Picker("Metric", selection: $metric) {
                    ForEach(CodeStatsTrendMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Cumulative", isOn: $cumulative)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                if let brushed {
                    Button(Self.zoomTitle(brushed)) {
                        actions.zoom(brushed.lowerBound, brushed.upperBound)
                        self.brushed = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            Chart {
                ForEach(projection.trend) { point in
                    if cumulative {
                        AreaMark(
                            x: .value("Period", point.date, unit: unit),
                            y: .value(metric.rawValue, total(point))
                        )
                        .foregroundStyle(DashSkin.accent(dark).opacity(0.25))
                        .interpolationMethod(.monotone)
                        LineMark(
                            x: .value("Period", point.date, unit: unit),
                            y: .value(metric.rawValue, total(point))
                        )
                        .foregroundStyle(DashSkin.accent(dark))
                        .interpolationMethod(.monotone)
                    } else {
                        BarMark(
                            x: .value("Period", point.date, unit: unit),
                            y: .value(metric.rawValue, value(point))
                        )
                        .foregroundStyle(
                            DashSkin.accent(dark).opacity(
                                selected?.date == point.date ? 0.95 : 0.55)
                        )
                        .cornerRadius(2)
                        LineMark(
                            x: .value("Period", point.date, unit: unit),
                            y: .value("Average", average(point))
                        )
                        .foregroundStyle(DashPalette.slate(dark))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: UIScale.pt(2)))
                    }
                }
                if let selected {
                    RuleMark(x: .value("Period", selected.date, unit: unit))
                        .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.5))
                        .annotation(
                            position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            tooltip(selected)
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartXSelection(range: $brushed)
            .chartGesture { proxy in
                SpatialTapGesture().onEnded { tap in
                    guard let date: Date = proxy.value(atX: tap.location.x),
                        let period = Calendar.current.dateInterval(of: unit, for: date)
                    else { return }
                    actions.zoom(period.start, period.end.addingTimeInterval(-1))
                }
                .simultaneously(
                    with: DragGesture(minimumDistance: 4).onChanged { drag in
                        guard let first: Date = proxy.value(atX: drag.startLocation.x),
                            let last: Date = proxy.value(atX: drag.location.x)
                        else { return }
                        brushed = min(first, last)...max(first, last)
                    })
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
            .frame(height: UIScale.pt(240))
        }
    }

    private func tooltip(_ point: CodeStatsTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(
                projection.trendGranularity == .monthly
                    ? point.date.formatted(.dateTime.month(.wide).year())
                    : "Week of " + point.date.formatted(date: .abbreviated, time: .omitted)
            )
            .font(.system(size: UIScale.pt(11), weight: .semibold))
            Text(CodeStatsNumberFormat.grouped(point.commits) + " commits")
            Text(CodeStatsNumberFormat.grouped(point.lines) + " lines")
            Text(
                "Running total \(CodeStatsNumberFormat.compact(point.totalLines)) lines, \(CodeStatsNumberFormat.grouped(point.totalCommits)) commits"
            )
            .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .font(.system(size: UIScale.pt(10.5)))
        .monospacedDigit()
        .foregroundStyle(DashSkin.ink(dark))
        .padding(UIScale.pt(8))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(8)).stroke(DashSkin.lineStrong(dark)))
    }

    private static func zoomTitle(_ range: ClosedRange<Date>) -> String {
        let start = range.lowerBound.formatted(date: .abbreviated, time: .omitted)
        let end = range.upperBound.formatted(date: .abbreviated, time: .omitted)
        return "Zoom to \(start) to \(end)"
    }

    private func value(_ point: CodeStatsTrendPoint) -> Int {
        metric == .lines ? point.lines : point.commits
    }

    private func total(_ point: CodeStatsTrendPoint) -> Int {
        metric == .lines ? point.totalLines : point.totalCommits
    }

    private func average(_ point: CodeStatsTrendPoint) -> Double {
        metric == .lines ? point.rollingLines : point.rollingCommits
    }
}

struct CodeStatsRepositoryCards: View {
    let projection: CodeStatsProjection
    let dark: Bool
    @Environment(\.codeStatsActions) private var actions
    @State private var logScale: Bool

    init(projection: CodeStatsProjection, dark: Bool, logScale: Bool = false) {
        self.projection = projection
        self.dark = dark
        _logScale = State(initialValue: logScale)
    }

    private var maximum: Double {
        Double(max(projection.repositoryBars.map(\.commits).max() ?? 1, 1))
    }

    private var domain: ClosedRange<Double> {
        logScale ? 1...(maximum * 3) : 0...(maximum * 1.3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            SkinCard(
                title: "Commits per repository",
                note: "Top 10, click to filter, right-click a row below to exclude", dark: dark
            ) {
                Toggle("Log scale", isOn: $logScale)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Chart(projection.repositoryBars, id: \.repository) { summary in
                    BarMark(
                        xStart: .value("Base", logScale ? 1 : 0),
                        xEnd: .value("Commits", max(summary.commits, 1)),
                        y: .value("Repository", summary.repository)
                    )
                    .foregroundStyle(
                        DashSkin.accent(dark).opacity(
                            actions.selectedRepositories.isEmpty
                                || actions.selectedRepositories.contains(summary.repository)
                                ? 0.85 : 0.3)
                    )
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text(
                            "\(CodeStatsNumberFormat.grouped(summary.commits)) commits, \(CodeStatsNumberFormat.compact(summary.counts.authored)) lines"
                        )
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().font(.system(size: UIScale.pt(10.5)))
                    }
                }
                .chartXScale(domain: domain, type: logScale ? .log : .linear)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let frame = proxy.plotFrame else { return }
                                let y = location.y - geometry[frame].origin.y
                                if let name: String = proxy.value(atY: y) {
                                    actions.toggleRepository(name)
                                }
                            }
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
    @State private var hovered: Date?

    private var monthLines: [String] {
        month.sorted { $0.value > $1.value }.map { point in
            let value =
                percent
                ? CodeStatsNumberFormat.percent(point.value * 100)
                : CodeStatsNumberFormat.grouped(Int(point.value))
            return "\(point.series): \(value)"
        }
    }

    private var month: [CodeStatsStackPoint] {
        guard let hovered else { return [] }
        return points.filter {
            Calendar.current.isDate($0.date, equalTo: hovered, toGranularity: .month)
                && $0.value > 0
        }
    }

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
            .chartXSelection(value: $hovered)
            .chartOverlay { _ in
                if let first = month.first {
                    VStack {
                        HStack {
                            Spacer()
                            CodeStatsTooltip(
                                title: first.date.formatted(.dateTime.month(.wide).year()),
                                lines: monthLines, dark: dark)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
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
    @Environment(\.codeStatsActions) private var actions
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
                        Button {
                            actions.toggleRepository(row.repository)
                        } label: {
                            HStack(spacing: UIScale.pt(4)) {
                                if actions.selectedRepositories.contains(row.repository) {
                                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                        .foregroundStyle(DashSkin.accent(dark))
                                }
                                Text(row.repository)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                        }
                        .buttonStyle(.plain)
                        .help("Filter the page to this repository")
                        .contextMenu {
                            Button("Show only " + row.repository) {
                                actions.toggleRepository(row.repository)
                            }
                            Button("Exclude " + row.repository) {
                                actions.excludeRepository(row.repository)
                            }
                        }
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
