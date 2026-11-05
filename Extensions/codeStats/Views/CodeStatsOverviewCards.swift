import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsRangeChips: View {
    let range: CodeStatsRange
    let select: (CodeStatsRange) -> Void

    var body: some View {
        ForEach(CodeStatsRange.presets, id: \.self) { preset in
            PageChip(Self.title(preset), active: preset == range) { select(preset) }
        }
    }

    static func title(_ range: CodeStatsRange) -> String {
        switch range {
        case .days(let count): "\(count) days"
        case .year: "1 year"
        case .all: "All time"
        case .between(let start, let end): start + " to " + end
        }
    }
}

struct CodeStatsKPIGrid: View {
    let report: CodeStatsReport
    let dark: Bool

    private var spacing: CGFloat { UIScale.pt(PageMetrics.cardSpacing) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                commits
                lines
                activeDays
                streak
                repositories
            }
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                GridRow {
                    commits.gridCellColumns(2)
                    lines.gridCellColumns(2)
                    activeDays.gridCellColumns(2)
                }
                GridRow {
                    streak.gridCellColumns(3)
                    repositories.gridCellColumns(3)
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(170)), spacing: spacing)],
                spacing: spacing
            ) {
                commits
                lines
                activeDays
                streak
                repositories
            }
        }
    }

    private var commits: some View {
        CodeStatsTile(
            label: "Commits", value: CodeStatsNumberFormat.compact(report.totals.commits),
            symbol: "point.3.connected.trianglepath.dotted",
            change: report.momentum?.commitChange,
            detail: commitsPerDay(report.totals), dark: dark)
    }

    private var lines: some View {
        CodeStatsTile(
            label: "Lines authored", value: CodeStatsNumberFormat.compact(report.totals.authored),
            symbol: "text.line.first.and.arrowtriangle.forward",
            change: report.momentum?.lineChange,
            detail:
                "+\(CodeStatsNumberFormat.grouped(report.totals.added)) / -\(CodeStatsNumberFormat.grouped(report.totals.deleted))",
            dark: dark)
    }

    private var activeDays: some View {
        CodeStatsTile(
            label: "Active days", value: CodeStatsNumberFormat.grouped(report.totals.activeDays),
            symbol: "calendar",
            detail:
                "\(CodeStatsNumberFormat.decimal(report.totals.averagePerActiveDay)) lines per active day",
            dark: dark)
    }

    private var streak: some View {
        CodeStatsTile(
            label: "Streak",
            value: CodeStatsNumberFormat.grouped(report.totals.currentStreak) + "d",
            symbol: "flame",
            detail: "Longest " + CodeStatsNumberFormat.grouped(report.totals.longestStreak)
                + " days",
            dark: dark)
    }

    private var repositories: some View {
        CodeStatsTile(
            label: "Repositories", value: CodeStatsNumberFormat.grouped(report.totals.repositories),
            symbol: "shippingbox",
            detail: "Net " + CodeStatsNumberFormat.grouped(report.totals.net) + " lines",
            dark: dark)
    }
}

private func commitsPerDay(_ totals: CodeStatsTotals) -> String {
    let perDay = totals.activeDays > 0 ? Double(totals.commits) / Double(totals.activeDays) : 0
    return CodeStatsNumberFormat.decimal(perDay) + " per active day"
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
    @State private var width = 0.0
    @Environment(\.compactLayout) private var compact

    private var cellSize: CGFloat {
        guard !weeks.isEmpty, width > 0 else { return 14 }
        let fitted = (width / UIScale.current - 16) / CGFloat(weeks.count) - 3
        return min(compact ? 20 : 28, max(14, fitted.rounded(.down)))
    }

    var body: some View {
        PageCard(
            title: "Contributions", note: "Commits per day, hover a day for details", fill: true
        ) {
            CodeStatsHeatGrid(weeks: weeks, dark: dark, cellSize: cellSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: Double.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
        }
    }
}

struct CodeStatsActivityRow: View {
    static let sharedRowWeeks = 27

    let projection: CodeStatsProjection
    let dark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                heatmap.frame(minWidth: UIScale.pt(420))
                topDays.frame(width: UIScale.pt(CodeStatsTopDaysCard.width))
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                heatmap
                topDays
            }
        }
    }

    private var heatmap: some View {
        CodeStatsHeatmapCard(weeks: projection.heatWeeks, dark: dark)
    }

    private var topDays: some View {
        CodeStatsTopDaysCard(days: projection.topDays, dark: dark)
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
                .font(.edithText(.callout).weight(.semibold))
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
                    .font(.edithText(.subheadline))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(280), alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            PageCapsLabel(title)
            Text(value)
                .font(.edithText(.title3).weight(.semibold))
                .monospacedDigit()
        }
    }

    private func section(_ title: String, _ shares: [CodeStatsDayShare]) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            PageCapsLabel(title)
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
                .font(.edithText(.subheadline))
            }
        }
    }
}

enum CodeStatsHeat {
    static func color(_ level: Int, dark: Bool) -> Color {
        ActivityCalendarStyle.color(level, dark: dark)
    }
}
