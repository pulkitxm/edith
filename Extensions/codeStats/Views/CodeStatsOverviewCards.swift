import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsRangePicker: View {
    let range: CodeStatsRange
    let select: (CodeStatsRange) -> Void

    var body: some View {
        EdithSegmentedPicker(
            "Range",
            selection: Binding(get: { range }, set: { select($0) }),
            options: CodeStatsRange.presets, label: { Self.title($0) }
        )
        .labelsHidden()
        .fixedSize()
    }

    static func title(_ range: CodeStatsRange) -> String {
        switch range {
        case .days(let count): "\(count) days"
        case .year: "1 year"
        case .all: "All"
        case .between(let start, let end): start + " to " + end
        }
    }
}

struct CodeStatsKPIGrid: View {
    let report: CodeStatsReport
    let dark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(10)) { tiles }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(170)), spacing: UIScale.pt(10))],
                spacing: UIScale.pt(10)
            ) { tiles }
        }
    }

    @ViewBuilder private var tiles: some View {
        let totals = report.totals
        CodeStatsTile(
            label: "Commits", value: CodeStatsNumberFormat.compact(totals.commits),
            symbol: "point.3.connected.trianglepath.dotted",
            change: report.momentum?.commitChange, dark: dark)
        CodeStatsTile(
            label: "Lines authored", value: CodeStatsNumberFormat.compact(totals.authored),
            symbol: "text.line.first.and.arrowtriangle.forward",
            change: report.momentum?.lineChange,
            detail:
                "+\(CodeStatsNumberFormat.grouped(totals.added)) / -\(CodeStatsNumberFormat.grouped(totals.deleted))",
            dark: dark)
        CodeStatsTile(
            label: "Active days", value: CodeStatsNumberFormat.grouped(totals.activeDays),
            symbol: "calendar",
            detail:
                "\(CodeStatsNumberFormat.decimal(totals.averagePerActiveDay)) lines per active day",
            dark: dark)
        CodeStatsTile(
            label: "Streak", value: CodeStatsNumberFormat.grouped(totals.currentStreak) + "d",
            symbol: "flame",
            detail: "Longest " + CodeStatsNumberFormat.grouped(totals.longestStreak) + " days",
            dark: dark)
        CodeStatsTile(
            label: "Repositories", value: CodeStatsNumberFormat.grouped(totals.repositories),
            symbol: "shippingbox",
            detail: "Net " + CodeStatsNumberFormat.grouped(totals.net) + " lines", dark: dark)
    }
}

struct CodeStatsTile: View {
    let label: String
    let value: String
    let symbol: String
    var change: Double?
    var detail: String?
    let dark: Bool

    var body: some View {
        PageMetric(
            title: label, value: value,
            detail: detail ?? (change == nil ? " " : "vs previous period"), symbol: symbol,
            tint: DashSkin.accent(dark), trend: change.map { CodeStatsNumberFormat.percent($0) },
            trendPositive: (change ?? 0) >= 0
        )
        .frame(minWidth: UIScale.pt(170))
    }
}

struct CodeStatsHeatmapCard: View {
    let weeks: [CodeStatsHeatWeek]
    let dark: Bool

    var body: some View {
        PageCard(
            title: "Contributions", note: "Commits per day, hover a day for details"
        ) {
            CodeStatsHeatGrid(weeks: weeks, dark: dark)
        }
    }
}

struct CodeStatsHeatGrid: View {
    let weeks: [CodeStatsHeatWeek]
    let dark: Bool
    var cellSize: CGFloat = 14
    @Environment(\.codeStatsActions) private var actions
    var body: some View {
        let cells = Dictionary(uniqueKeysWithValues: weeks.flatMap(\.cells).map { ($0.id, $0) })
        let calendarWeeks = weeks.map { week in
            ActivityCalendarWeek(
                id: week.id, monthLabel: week.monthLabel,
                cells: week.cells.map {
                    ActivityCalendarDay(
                        id: $0.id, date: $0.date, value: Double($0.commits), level: $0.level)
                })
        }
        ActivityCalendarGrid(weeks: calendarWeeks, dark: dark, cellSize: cellSize) { day in
            if let cell = cells[day.id] {
                CodeStatsDayPopover(cell: cell, detail: actions.dayDetails[cell.id], dark: dark)
            }
        }
    }
}

struct CodeStatsDayPopover: View {
    let cell: CodeStatsHeatCell
    let detail: CodeStatsDayDetail?
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text(cell.date?.formatted(date: .complete, time: .omitted) ?? cell.id)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
            HStack(spacing: UIScale.pt(14)) {
                metric("Commits", CodeStatsNumberFormat.grouped(detail?.commits ?? cell.commits))
                metric("Lines", CodeStatsNumberFormat.compact(detail?.lines ?? cell.lines))
            }
            if let detail, !detail.repositories.isEmpty {
                section("Repositories", detail.repositories)
            }
            if let detail, !detail.languages.isEmpty {
                section("Languages", detail.languages)
            }
            if (detail?.commits ?? cell.commits) == 0 {
                Text("No commits on this day.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(280), alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text(title.uppercased())
                .font(DashSkin.mono(9))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(.system(size: UIScale.pt(16), weight: .semibold))
                .monospacedDigit()
        }
    }

    private func section(_ title: String, _ shares: [CodeStatsDayShare]) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            Text(title.uppercased())
                .font(DashSkin.mono(9))
                .foregroundStyle(DashSkin.inkFaint(dark))
            ForEach(shares, id: \.name) { share in
                HStack {
                    Text(share.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(
                        "\(CodeStatsNumberFormat.grouped(share.commits)) c, \(CodeStatsNumberFormat.compact(share.lines))"
                    )
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .monospacedDigit()
                }
                .font(.system(size: UIScale.pt(11)))
            }
        }
    }
}

enum CodeStatsHeat {
    static func color(_ level: Int, dark: Bool) -> Color {
        ActivityCalendarStyle.color(level, dark: dark)
    }
}
