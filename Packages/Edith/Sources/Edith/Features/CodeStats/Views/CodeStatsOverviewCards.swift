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
        SkinCard(
            title: "Contributions", note: "Commits per day, hover a day for details", dark: dark
        ) {
            CodeStatsHeatGrid(weeks: weeks, dark: dark)
            CodeStatsHeatLegend(dark: dark)
        }
    }
}

struct CodeStatsHeatGrid: View {
    let weeks: [CodeStatsHeatWeek]
    let dark: Bool
    var cellSize: CGFloat = 14
    @Environment(\.codeStatsActions) private var actions
    @State private var hovered: String?

    var body: some View {
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
                                cellView(cell)
                            }
                        }
                        .frame(width: UIScale.pt(cellSize), alignment: .top)
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
            .defaultScrollAnchor(weeks.count > 30 ? .trailing : .leading)
        }
        .frame(height: UIScale.pt(cellSize * 7 + 3 * 6 + 18))
    }

    private func cellView(_ cell: CodeStatsHeatCell) -> some View {
        RoundedRectangle(cornerRadius: UIScale.pt(3))
            .fill(CodeStatsHeat.color(cell.level, dark: dark))
            .frame(width: UIScale.pt(cellSize), height: UIScale.pt(cellSize))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(3))
                    .stroke(DashSkin.ink(dark).opacity(hovered == cell.id ? 0.6 : 0))
            }
            .onHover { inside in
                guard cell.date != nil else { return }
                if inside { hovered = cell.id } else if hovered == cell.id { hovered = nil }
            }
            .popover(
                isPresented: Binding(
                    get: { hovered == cell.id },
                    set: { shown in if !shown, hovered == cell.id { hovered = nil } }),
                arrowEdge: .trailing
            ) {
                CodeStatsDayPopover(cell: cell, detail: actions.dayDetails[cell.id], dark: dark)
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
