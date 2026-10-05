import EdithKit
import SwiftUI

struct CodeStatsRangePicker: View {
    let range: CodeStatsRange
    let select: (CodeStatsRange) -> Void

    var body: some View {
        Picker(
            "Range",
            selection: Binding(get: { range }, set: { select($0) })
        ) {
            ForEach(CodeStatsRange.presets, id: \.self) { preset in
                Text(Self.title(preset)).tag(preset)
            }
        }
        .pickerStyle(.segmented)
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
        let totals = report.totals
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(170)), spacing: UIScale.pt(10))],
            spacing: UIScale.pt(10)
        ) {
            CodeStatsTile(
                label: "Commits", value: CodeStatsNumberFormat.compact(totals.commits),
                symbol: "point.3.connected.trianglepath.dotted",
                change: report.momentum?.commitChange, dark: dark)
            CodeStatsTile(
                label: "Lines authored", value: CodeStatsNumberFormat.compact(totals.authored),
                symbol: "text.line.first.and.arrowtriangle.forward",
                change: report.momentum?.lineChange,
                detail: "+" + CodeStatsNumberFormat.grouped(totals.added) + " / -"
                    + CodeStatsNumberFormat.grouped(totals.deleted),
                dark: dark)
            CodeStatsTile(
                label: "Active days", value: CodeStatsNumberFormat.grouped(totals.activeDays),
                symbol: "calendar",
                detail:
                    CodeStatsNumberFormat.decimal(totals.averagePerActiveDay)
                    + " lines per active day",
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
}

struct CodeStatsTile: View {
    let label: String
    let value: String
    let symbol: String
    var change: Double?
    var detail: String?
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.accent(dark))
                Text(label.uppercased())
                    .font(DashSkin.mono(10)).tracking(UIScale.pt(1.2))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
            Text(value)
                .font(DashSkin.heading(24))
                .foregroundStyle(DashSkin.ink(dark))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: UIScale.pt(6)) {
                if let change {
                    Label(
                        CodeStatsNumberFormat.percent(change),
                        systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(change >= 0 ? DashSkin.ok : DashSkin.danger)
                    .help("Compared with the previous period of the same length")
                }
                Text(detail ?? (change == nil ? " " : "vs previous period"))
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

struct CodeStatsHeatmapCard: View {
    let weeks: [CodeStatsHeatWeek]
    let dark: Bool

    var body: some View {
        SkinCard(title: "Contributions", note: "Commits per day", dark: dark) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: UIScale.pt(3)) {
                        ForEach(weeks) { week in
                            VStack(spacing: UIScale.pt(3)) {
                                Text(week.monthLabel)
                                    .font(.system(size: UIScale.pt(9)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                    .frame(height: UIScale.pt(12))
                                    .fixedSize()
                                ForEach(week.cells) { cell in
                                    CodeStatsHeatCellView(cell: cell, dark: dark)
                                }
                            }
                            .frame(width: UIScale.pt(14), alignment: .top)
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .defaultScrollAnchor(weeks.count > 30 ? .trailing : .leading)
            }
            .frame(height: UIScale.pt(134))
            CodeStatsHeatLegend(dark: dark)
        }
    }
}

private struct CodeStatsHeatCellView: View {
    let cell: CodeStatsHeatCell
    let dark: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(3))
            .fill(CodeStatsHeat.color(cell.level, dark: dark))
            .frame(width: UIScale.pt(14), height: UIScale.pt(14))
            .help(help)
    }

    private var help: String {
        guard let date = cell.date else { return "" }
        let day = date.formatted(date: .abbreviated, time: .omitted)
        let commits = CodeStatsNumberFormat.grouped(cell.commits)
        let lines = CodeStatsNumberFormat.grouped(cell.lines)
        return "\(day): \(commits) commits, \(lines) lines"
    }
}

private struct CodeStatsHeatLegend: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(3)) {
            Spacer()
            Text("Less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: UIScale.pt(2))
                    .fill(CodeStatsHeat.color(level, dark: dark))
                    .frame(width: UIScale.pt(10), height: UIScale.pt(10))
            }
            Text("More")
        }
        .font(.system(size: UIScale.pt(9)))
        .foregroundStyle(DashSkin.inkFaint(dark))
    }
}

enum CodeStatsHeat {
    static func color(_ level: Int, dark: Bool) -> Color {
        switch level {
        case ..<0: .clear
        case 0: DashSkin.grid(dark)
        default: DashSkin.heat(level - 1, dark)
        }
    }
}
