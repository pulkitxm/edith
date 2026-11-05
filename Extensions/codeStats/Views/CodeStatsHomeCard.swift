import EdithExtensionSupport
import EdithExtensionUI
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
    @State private var model: CodeStatsModel
    @State private var summary: CodeStatsHomeSummary?
    @State private var loading = ContentLoad()
    @State private var retry = 0

    init(dark: Bool, model: CodeStatsModel? = nil) {
        self.dark = dark
        _model = State(initialValue: model ?? CodeStatsModel.shared)
    }

    var body: some View {
        PageCard(title: "Code Stats", note: "Last 30 days") {
            LoadingContainer(
                state: loading.state, title: "No code stats yet",
                errorTitle: "Code Stats could not load",
                message: loading.errorMessage
                    ?? "Set up Code Stats to start counting your commits.",
                retry: { retry += 1 }, refreshing: loading.isRefreshing
            ) {
                if let summary { content(summary) }
            } placeholder: {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    PageSkeletonControls()
                    ActivityCalendarSkeleton(cellSize: 11)
                    SkeletonBlock(width: 180, height: 14)
                }
            }
            if loading.state == .empty {
                Button("Open Code Stats") {
                    SharedDefaults.store.set(
                        "codeStats", forKey: AppStorageKeys.General.mainWindowSection)
                }.buttonStyle(.edith(.borderless))
            }
        }
        .pageTask(id: "\(model.tableRevision):\(retry)", cancel: { loading.cancel() }) {
            await loadSummary()
        }
    }

    private func loadSummary() async {
        let request = loading.begin()
        defer { if Task.isCancelled { loading.cancel(request) } }
        if model.table == nil { await model.refresh() } else { await model.loadStatus() }
        guard loading.isCurrent(request) else { return }
        if let error = model.loadingError {
            loading.fail(request, message: error)
            return
        }
        let next = await model.homeSummary()
        guard loading.isCurrent(request) else { return }
        summary = next
        loading.complete(request, empty: next == nil)
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
                        .font(.edithText(.subheadline))
                    }
                }
            }
            Button("Open Code Stats") {
                SharedDefaults.store.set(
                    "codeStats", forKey: AppStorageKeys.General.mainWindowSection)
            }.buttonStyle(.edith(.borderless))
        }
    }

    private func metric(_ title: String, _ value: String, change: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            PageCapsLabel(title)
            Text(value)
                .font(.edithText(.title2).weight(.semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .monospacedDigit()
            if let change {
                Text(CodeStatsNumberFormat.signedPercent(change))
                    .font(.edithText(.caption).weight(.medium))
                    .foregroundStyle(change >= 0 ? DashSkin.ok : DashSkin.warn)
            }
        }
    }
}
