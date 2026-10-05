import EdithKit
import SwiftUI

struct CodeStatsHomeSummary: Equatable, Sendable {
    static let heatDays = 126

    let totals: CodeStatsTotals
    let momentum: CodeStatsMomentum?
    let topRepositories: [CodeStatsRepositorySummary]
    let weeks: [CodeStatsHeatWeek]
    let days: [String: CodeStatsDayDetail]
}

struct CodeStatsHomeCard: View {
    let dark: Bool
    @State private var model = CodeStatsModel.shared
    @State private var summary: CodeStatsHomeSummary?
    @State private var loaded = false
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    var body: some View {
        SkinCard(title: "Code Stats", note: "Last 30 days", dark: dark) {
            if let summary {
                content(summary)
            } else if loaded {
                Text("No code stats yet. Set up the mirror to start counting.")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                JumpLink(title: "Open Code Stats", destination: .codeStats, dark: dark)
            } else {
                SkeletonGroup {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        SkeletonBlock(width: UIScale.pt(220), height: UIScale.pt(26))
                        SkeletonBlock(height: UIScale.pt(110))
                        SkeletonBlock(width: UIScale.pt(180), height: UIScale.pt(14))
                    }
                }
            }
        }
        .task(id: model.table?.rows.count ?? -1) {
            guard automaticActionsEnabled else { return }
            if model.table == nil { await model.refresh() }
            summary = await model.homeSummary()
            loaded = true
        }
    }

    private func content(_ summary: CodeStatsHomeSummary) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(18)) {
                metric(
                    "Commits", CodeStatsNumberFormat.grouped(summary.totals.commits),
                    change: summary.momentum?.commitChange)
                metric(
                    "Lines", CodeStatsNumberFormat.compact(summary.totals.authored),
                    change: summary.momentum?.lineChange)
                metric("Active days", CodeStatsNumberFormat.grouped(summary.totals.activeDays))
                metric("Streak", "\(summary.totals.currentStreak)d")
            }
            CodeStatsHeatGrid(weeks: summary.weeks, dark: dark, cellSize: 11)
                .environment(\.codeStatsActions, CodeStatsActions(dayDetails: summary.days))
            if !summary.topRepositories.isEmpty {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    ForEach(summary.topRepositories, id: \.repository) { repository in
                        HStack {
                            Text(repository.repository)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(DashSkin.ink(dark))
                            Spacer()
                            Text("\(CodeStatsNumberFormat.grouped(repository.commits)) commits")
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .monospacedDigit()
                        }
                        .font(.system(size: UIScale.pt(11.5)))
                    }
                }
            }
            JumpLink(title: "Open Code Stats", destination: .codeStats, dark: dark)
        }
    }

    private func metric(_ title: String, _ value: String, change: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text(title.uppercased())
                .font(DashSkin.mono(9))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value)
                .font(.system(size: UIScale.pt(17), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .monospacedDigit()
            if let change {
                Text(CodeStatsNumberFormat.signedPercent(change))
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(change >= 0 ? DashSkin.ok : DashSkin.warn)
            }
        }
    }
}
