import Charts
import EdithKit
import SwiftUI

struct CodeStatsTooltip: View {
    let title: String
    let lines: [String]
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(title).font(.system(size: UIScale.pt(11), weight: .semibold))
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.system(size: UIScale.pt(10.5)))
        .monospacedDigit()
        .foregroundStyle(DashSkin.ink(dark))
        .padding(UIScale.pt(8))
        .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(8)).stroke(DashSkin.lineStrong(dark)))
    }
}

struct CodeStatsRepositoryStripCard: View {
    let explorer: CodeStatsExplorer
    let dark: Bool
    @Environment(\.codeStatsActions) private var actions
    @State private var hovered: CodeStatsStripCell?

    var body: some View {
        SkinCard(
            title: "Repository activity",
            note: "Each row scaled to its own busiest month, so small repos stay visible",
            dark: dark
        ) {
            if explorer.stripRepositories.isEmpty {
                Text("No repository activity in this range.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            } else {
                Grid(
                    alignment: .leading, horizontalSpacing: UIScale.pt(3),
                    verticalSpacing: UIScale.pt(5)
                ) {
                    ForEach(explorer.stripRepositories, id: \.self) { repository in
                        GridRow {
                            Button {
                                actions.toggleRepository(repository)
                            } label: {
                                Text(repository)
                                    .font(.system(size: UIScale.pt(11)))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: UIScale.pt(190), alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Filter the page to " + repository)
                            .contextMenu {
                                Button("Exclude " + repository) {
                                    actions.excludeRepository(repository)
                                }
                            }
                            ForEach(explorer.stripMonths) { month in
                                cell(explorer.stripCells[repository + "|" + month.month])
                            }
                        }
                    }
                    GridRow {
                        Text("")
                        ForEach(Array(explorer.stripMonths.enumerated()), id: \.element.id) {
                            index, month in
                            Text(
                                labelled(index)
                                    ? month.date.formatted(
                                        .dateTime.month(.abbreviated).year(.twoDigits))
                                    : ""
                            )
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    if let hovered {
                        Text(
                            hovered.repository + ", "
                                + hovered.date.formatted(.dateTime.month(.wide).year()) + ": "
                                + CodeStatsNumberFormat.grouped(hovered.commits) + " commits, "
                                + CodeStatsNumberFormat.compact(hovered.lines) + " lines")
                    } else {
                        Text("Hover a cell for details, click a name to filter.")
                    }
                    Spacer()
                }
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .monospacedDigit()
            }
        }
    }

    private func labelled(_ index: Int) -> Bool {
        let count = explorer.stripMonths.count
        let step = max(1, Int((Double(count) / 8).rounded(.up)))
        return index.isMultiple(of: step)
    }

    private func cell(_ value: CodeStatsStripCell?) -> some View {
        RoundedRectangle(cornerRadius: UIScale.pt(3))
            .fill(
                value.map { DashSkin.accent(dark).opacity(0.15 + 0.85 * $0.level) }
                    ?? DashSkin.grid(dark).opacity(0.6)
            )
            .frame(minWidth: UIScale.pt(4), maxWidth: .infinity)
            .frame(height: UIScale.pt(16))
            .overlay {
                if let value, hovered == value {
                    RoundedRectangle(cornerRadius: UIScale.pt(3))
                        .stroke(DashSkin.ink(dark), lineWidth: UIScale.pt(1))
                }
            }
            .onHover { inside in
                if inside { hovered = value } else if hovered == value { hovered = nil }
            }
            .onTapGesture { if let value { actions.toggleRepository(value.repository) } }
    }
}

struct CodeStatsYearOverYearCard: View {
    let explorer: CodeStatsExplorer
    let dark: Bool
    @State private var hovered: Int?
    @State private var commits = false

    private var colors: [Color] {
        explorer.yearNames.indices.map { DashPalette.categorical($0, dark: dark) }
    }

    var body: some View {
        SkinCard(title: "Year over year", note: "Same month, different years", dark: dark) {
            Picker("Metric", selection: $commits) {
                Text("Lines").tag(false)
                Text("Commits").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Chart {
                ForEach(explorer.years) { point in
                    LineMark(
                        x: .value("Month", point.month),
                        y: .value("Value", commits ? point.commits : point.lines)
                    )
                    .foregroundStyle(by: .value("Year", point.year))
                    .interpolationMethod(.monotone)
                    .symbol(by: .value("Year", point.year))
                }
                if let hovered {
                    RuleMark(x: .value("Month", hovered))
                        .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.5))
                        .annotation(
                            position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            CodeStatsTooltip(
                                title: Calendar.current.monthSymbols[hovered - 1],
                                lines: explorer.years.filter { $0.month == hovered }.map {
                                    $0.year + ": "
                                        + (commits
                                            ? CodeStatsNumberFormat.grouped($0.commits) + " commits"
                                            : CodeStatsNumberFormat.compact($0.lines) + " lines")
                                }, dark: dark)
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartXScale(domain: 1...12)
            .chartXAxis {
                AxisMarks(values: Array(1...12)) { value in
                    AxisValueLabel {
                        if let month = value.as(Int.self) {
                            Text(Calendar.current.shortMonthSymbols[month - 1])
                                .font(.system(size: UIScale.pt(9)))
                        }
                    }
                }
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
            .chartForegroundStyleScale(domain: explorer.yearNames, range: colors)
            .chartLegend(.hidden)
            .frame(height: UIScale.pt(220))
            AdaptiveChartLegend(
                items: zip(explorer.yearNames, colors).map {
                    ChartLegendItem(id: $0.0, label: $0.0, color: $0.1)
                })
        }
    }
}

struct CodeStatsRhythmCard: View {
    let explorer: CodeStatsExplorer
    let dark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                CodeStatsRhythmChart(
                    title: "By weekday", bars: explorer.weekdays, dark: dark
                ).frame(minWidth: UIScale.pt(300))
                CodeStatsRhythmChart(
                    title: "By hour of day", bars: explorer.hours, dark: dark
                ).frame(minWidth: UIScale.pt(420))
            }
            VStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                CodeStatsRhythmChart(title: "By weekday", bars: explorer.weekdays, dark: dark)
                CodeStatsRhythmChart(title: "By hour of day", bars: explorer.hours, dark: dark)
            }
        }
    }
}

private struct CodeStatsRhythmChart: View {
    let title: String
    let bars: [CodeStatsRhythmBar]
    let dark: Bool
    @State private var hovered: String?

    var body: some View {
        SkinCard(title: title, note: "Commits, hover for lines", dark: dark, fill: true) {
            Chart(bars) { bar in
                BarMark(x: .value("When", bar.label), y: .value("Commits", bar.commits))
                    .foregroundStyle(
                        DashSkin.accent(dark).opacity(
                            hovered == nil || hovered == bar.label ? 0.85 : 0.35)
                    )
                    .cornerRadius(2)
                    .annotation(position: .top) {
                        if hovered == bar.label {
                            CodeStatsTooltip(
                                title: bar.label,
                                lines: [
                                    CodeStatsNumberFormat.grouped(bar.commits) + " commits",
                                    CodeStatsNumberFormat.compact(bar.lines) + " lines",
                                ], dark: dark)
                        }
                    }
            }
            .chartXSelection(value: $hovered)
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
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.system(size: UIScale.pt(9))) }
            }
            .frame(height: UIScale.pt(170))
        }
    }
}

struct CodeStatsShareCard: View {
    let explorer: CodeStatsExplorer
    let dark: Bool
    @Environment(\.codeStatsActions) private var actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                donut("Repositories", explorer.repositories, owner: false)
                donut("Owners", explorer.owners, owner: true)
            }
            VStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                donut("Repositories", explorer.repositories, owner: false)
                donut("Owners", explorer.owners, owner: true)
            }
        }
    }

    private func donut(_ title: String, _ slices: [CodeStatsSlice], owner: Bool) -> some View {
        CodeStatsDonut(
            title: title, slices: slices, dark: dark,
            select: { slice in
                guard !slice.isOther else { return }
                if owner {
                    actions.toggleOwner(slice.name)
                } else {
                    actions.toggleRepository(slice.name)
                }
            })
    }
}

private struct CodeStatsDonut: View {
    let title: String
    let slices: [CodeStatsSlice]
    let dark: Bool
    let select: (CodeStatsSlice) -> Void
    @State private var angle: Int?

    private var colors: [Color] {
        slices.indices.map { DashPalette.categorical($0, dark: dark) }
    }

    private var hovered: CodeStatsSlice? {
        guard let angle else { return nil }
        var running = 0
        for slice in slices {
            running += slice.lines
            if angle <= running { return slice }
        }
        return nil
    }

    var body: some View {
        SkinCard(
            title: title, note: "Share of lines, click a slice to filter", dark: dark, fill: true
        ) {
            HStack(alignment: .center, spacing: UIScale.pt(16)) {
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("Lines", slice.lines), innerRadius: .ratio(0.6),
                        angularInset: 1.2
                    )
                    .foregroundStyle(by: .value("Name", slice.name))
                    .opacity(hovered == nil || hovered == slice ? 1 : 0.4)
                    .cornerRadius(3)
                }
                .chartForegroundStyleScale(domain: slices.map(\.name), range: colors)
                .chartLegend(.hidden)
                .chartAngleSelection(value: $angle)
                .chartBackground { _ in
                    VStack(spacing: UIScale.pt(1)) {
                        if let hovered {
                            Text(CodeStatsNumberFormat.percent(hovered.share * 100))
                                .font(.system(size: UIScale.pt(16), weight: .semibold))
                            Text(CodeStatsNumberFormat.compact(hovered.lines) + " lines")
                                .font(.system(size: UIScale.pt(10)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    .monospacedDigit()
                }
                .onTapGesture { if let hovered { select(hovered) } }
                .frame(width: UIScale.pt(170), height: UIScale.pt(170))
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                        Button {
                            select(slice)
                        } label: {
                            HStack(spacing: UIScale.pt(6)) {
                                Circle().fill(colors[index])
                                    .frame(width: UIScale.pt(8), height: UIScale.pt(8))
                                Text(slice.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(CodeStatsNumberFormat.percent(slice.share * 100))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                    .monospacedDigit()
                            }
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.ink(dark))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(slice.isOther)
                    }
                }
            }
        }
    }
}

struct CodeStatsNewRepositoriesCard: View {
    let explorer: CodeStatsExplorer
    let dark: Bool
    @State private var hovered: Date?

    private var selected: CodeStatsMonthCount? {
        guard let hovered else { return nil }
        return explorer.newRepositories.first {
            Calendar.current.isDate($0.date, equalTo: hovered, toGranularity: .month)
        }
    }

    var body: some View {
        SkinCard(title: "New repositories", note: "Month of your first commit in each", dark: dark)
        {
            if explorer.newRepositories.isEmpty {
                Text("You did not start any new repositories in this range.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        VStack {
            Chart {
                ForEach(explorer.newRepositories) { month in
                    BarMark(
                        x: .value("Month", month.date, unit: .month),
                        y: .value("Repositories", month.count)
                    )
                    .foregroundStyle(DashPalette.slate(dark).opacity(0.75))
                    .cornerRadius(2)
                }
                if let selected {
                    RuleMark(x: .value("Month", selected.date, unit: .month))
                        .foregroundStyle(DashSkin.inkFaint(dark).opacity(0.4))
                        .annotation(
                            position: .top, spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            CodeStatsTooltip(
                                title: selected.date.formatted(.dateTime.month(.wide).year()),
                                lines: Array(selected.names.prefix(6))
                                    + (selected.names.count > 6
                                        ? ["and \(selected.names.count - 6) more"] : []),
                                dark: dark)
                        }
                }
            }
            .chartXSelection(value: $hovered)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel().font(.system(size: UIScale.pt(9)))
                }
            }
            .frame(height: UIScale.pt(160))
        }
    }
}
