import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsLanguageCards: View {
    let projection: CodeStatsProjection
    let dark: Bool
    @Environment(\.codeStatsActions) private var actions

    var body: some View {
        if projection.showsStackedTrend {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    shares.frame(minWidth: UIScale.pt(320))
                    overTime.frame(minWidth: UIScale.pt(420))
                }
                VStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                    shares
                    overTime
                }
            }
        } else {
            shares
        }
    }

    private var shares: some View {
        PageCard(title: "Languages", note: "Share of lines authored", fill: true) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                ForEach(Array(projection.languageShares.enumerated()), id: \.element.id) {
                    index, share in
                    Button {
                        actions.toggleLanguage(share.name)
                    } label: {
                        CodeStatsShareRow(
                            share: share, color: DashPalette.categorical(index, dark: dark),
                            dark: dark
                        )
                        .opacity(
                            actions.selectedLanguages.isEmpty
                                || actions.selectedLanguages.contains(share.name) ? 1 : 0.45
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.edith(.borderless))
                    .help("Filter the page to " + share.name)
                }
                if projection.languageShares.isEmpty {
                    Text("No language data in this range.")
                        .font(.edithText(.callout))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
        }
    }

    private var overTime: some View {
        CodeStatsStackedCard(
            title: "Languages over time",
            note: projection.stackGranularity == .daily ? "Daily share" : "Monthly share",
            points: projection.languageMonthly, series: projection.languageSeries, percent: true,
            granularity: projection.stackGranularity, dark: dark)
    }
}

private struct CodeStatsShareRow: View {
    let share: CodeStatsShare
    let color: Color
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            HStack {
                Circle().fill(color).frame(width: UIScale.pt(8), height: UIScale.pt(8))
                Text(share.name)
                    .font(.edithText(.callout).weight(.medium))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Text(CodeStatsNumberFormat.compact(share.lines) + " lines")
                    .font(.edithText(.subheadline))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(CodeStatsNumberFormat.percent(share.share * 100))
                    .font(.edithText(.callout).weight(.semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                    .frame(width: UIScale.pt(40), alignment: .trailing)
            }
            .monospacedDigit()
            GeometryReader { proxy in
                Capsule()
                    .fill(DashSkin.grid(dark))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * min(max(share.share, 0), 1))
                    }
            }
            .frame(height: UIScale.pt(5))
        }
    }
}

struct CodeStatsHabitCards: View {
    let projection: CodeStatsProjection
    let dark: Bool
    @Environment(\.compactLayout) private var compact

    var body: some View {
        if compact {
            VStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                punchcard
                topDays
            }
        } else {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                punchcard
                topDays.frame(width: UIScale.pt(CodeStatsTopDaysCard.width))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var topDays: some View {
        CodeStatsTopDaysCard(days: projection.topDays, dark: dark)
    }

    private var punchcard: some View {
        PageCard(title: "When you commit", note: "Weekday by hour", fill: true) {
            CodeStatsPunchcardGrid(projection: projection, dark: dark)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-stats-punchcard")
    }
}

struct CodeStatsPunchcardGrid: View {
    static let minimumSide = 10.0
    static let maximumSide = 40.0
    static let gap = 2.0
    static let labelWidth = 28.0

    let projection: CodeStatsProjection
    let dark: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) {
                grid
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(Self.gap)) {
            ForEach(Array(projection.punchcardRows.enumerated()), id: \.offset) { row, name in
                HStack(spacing: UIScale.pt(Self.gap)) {
                    Text(name)
                        .font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(Self.labelWidth), alignment: .leading)
                    ForEach(projection.punchcard[(row * 24)..<(row * 24 + 24)]) { cell in
                        RoundedRectangle(cornerRadius: UIScale.pt(2))
                            .fill(CodeStatsHeat.color(cell.level, dark: dark))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(
                                minWidth: UIScale.pt(Self.minimumSide),
                                maxWidth: UIScale.pt(Self.maximumSide)
                            )
                            .help(
                                "\(cell.weekday) \(cell.hour):00, \(CodeStatsNumberFormat.grouped(cell.commits)) commits"
                            )
                    }
                }
            }
            HStack(spacing: UIScale.pt(Self.gap)) {
                Color.clear.frame(width: UIScale.pt(Self.labelWidth), height: UIScale.pt(1))
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour.isMultiple(of: 6) ? "\(hour)" : "")
                        .font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .fixedSize()
                        .frame(
                            minWidth: UIScale.pt(Self.minimumSide),
                            maxWidth: UIScale.pt(Self.maximumSide))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeStatsTopDaysCard: View {
    static let width = 300.0
    static let listMaximumWidth = 340.0

    let days: [CodeStatsTopDay]
    let dark: Bool

    var body: some View {
        PageCard(title: "Top days", note: "By lines authored", fill: true) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    HStack(spacing: UIScale.pt(8)) {
                        Text("\(index + 1)")
                            .font(.edithText(.caption))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(width: UIScale.pt(16), alignment: .trailing)
                        Text(
                            day.date?.formatted(date: .abbreviated, time: .omitted) ?? day.day
                        )
                        .font(.edithText(.callout).weight(.medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                        Spacer(minLength: UIScale.pt(8))
                        Text(CodeStatsNumberFormat.grouped(day.commits) + " commits")
                            .font(.edithText(.subheadline))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(CodeStatsNumberFormat.compact(day.lines))
                            .font(.edithText(.callout).weight(.semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                    }
                    .monospacedDigit()
                }
                if days.isEmpty {
                    Text("No commits in this range.")
                        .font(.edithText(.callout))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
            .frame(maxWidth: UIScale.pt(Self.listMaximumWidth), alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-stats-top-days")
    }
}
