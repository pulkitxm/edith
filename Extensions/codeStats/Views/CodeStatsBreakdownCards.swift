import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsLanguageCards: View {
    let projection: CodeStatsProjection
    let dark: Bool
    @Environment(\.codeStatsActions) private var actions

    var body: some View {
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
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
        }
    }

    private var overTime: some View {
        CodeStatsStackedCard(
            title: "Languages over time", note: "Monthly share", points: projection.languageMonthly,
            series: projection.languageSeries, percent: true, dark: dark)
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
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Text(CodeStatsNumberFormat.compact(share.lines) + " lines")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(CodeStatsNumberFormat.percent(share.share * 100))
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                punchcard.frame(minWidth: UIScale.pt(560))
                topDays.frame(width: UIScale.pt(300))
            }
            VStack(spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                punchcard
                topDays
            }
        }
    }

    private var punchcard: some View {
        PageCard(title: "When you commit", note: "Weekday by hour", fill: true) {
            ViewThatFits(in: .horizontal) {
                punchcardGrid
                ScrollView(.horizontal) {
                    punchcardGrid
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var punchcardGrid: some View {
        Grid(horizontalSpacing: UIScale.pt(2), verticalSpacing: UIScale.pt(2)) {
            ForEach(Array(projection.punchcardRows.enumerated()), id: \.offset) { row, name in
                GridRow {
                    Text(name)
                        .font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(28), alignment: .leading)
                    ForEach(projection.punchcard[(row * 24)..<(row * 24 + 24)]) { cell in
                        RoundedRectangle(cornerRadius: UIScale.pt(2))
                            .fill(CodeStatsHeat.color(cell.level, dark: dark))
                            .frame(minWidth: UIScale.pt(10), maxWidth: .infinity)
                            .frame(height: UIScale.pt(16))
                            .help(
                                "\(cell.weekday) \(cell.hour):00, \(CodeStatsNumberFormat.grouped(cell.commits)) commits"
                            )
                    }
                }
            }
            GridRow {
                Text("")
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour.isMultiple(of: 6) ? "\(hour)" : "")
                        .font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
    }

    private var topDays: some View {
        PageCard(title: "Top days", note: "By lines authored", fill: true) {
            VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                ForEach(Array(projection.topDays.enumerated()), id: \.element.id) { index, day in
                    HStack(spacing: UIScale.pt(8)) {
                        Text("\(index + 1)")
                            .font(DashSkin.mono(10))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(width: UIScale.pt(16), alignment: .trailing)
                        Text(
                            day.date?.formatted(date: .abbreviated, time: .omitted) ?? day.day
                        )
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        Spacer()
                        Text(CodeStatsNumberFormat.grouped(day.commits) + " commits")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(CodeStatsNumberFormat.compact(day.lines))
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                    }
                    .monospacedDigit()
                }
                if projection.topDays.isEmpty {
                    Text("No commits in this range.")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
        }
    }
}
