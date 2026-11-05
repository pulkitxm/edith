import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CodeStatsPage: View {
    @State private var model: CodeStatsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    init(model: CodeStatsModel? = nil) {
        _model = State(initialValue: model ?? CodeStatsModel())
    }

    private var dark: Bool { scheme == .dark }

    var body: some View {
        PageScaffold(
            width: model.phase == .setup ? .readable : .fluid, pinnedHeader: true,
            activity: model.activity
        ) {
            VStack(spacing: 0) {
                CodeStatsHeader(model: model)
                if model.table != nil {
                    CodeStatsFilterBar(model: model, dark: dark)
                        .pageGutter(compact)
                        .padding(.bottom, UIScale.pt(PageMetrics.headerBottom))
                }
                PageHeaderDivider()
            }
        } content: {
            if model.report != nil, let error = model.statusLoad.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry") { Task { await model.refresh() } }
                    })
            }
            ForEach(model.banners) { banner in
                CodeStatsBannerView(banner: banner, choose: chooseFolder) {
                    Task { await model.loadReport() }
                }
            }
            if let progress = model.progress {
                CodeStatsProgressCard(
                    progress: progress, trigger: model.status?.state.active?.trigger,
                    cancelling: model.isCancelling
                ) {
                    Task { await model.cancel() }
                }
            }
            PageLoading(
                state: model.loadingState,
                message: model.loadingError ?? "Code Stats could not load its results.",
                layout: .analytics, activity: model.activity,
                retry: { Task { await model.refresh() } }
            ) { content }
        }
        .pageTask(cancel: model.cancelLoading) {
            await model.observe()
        }
        .alert(
            "Code Stats",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            EmptyView()
        case .firstRun:
            PageEmptyState(
                icon: .sync, title: "Your first sync is running",
                message:
                    "Edith is copying and reading your repositories in the background. You can leave this page or close the window; your stats appear here when it finishes.",
                footnote: "The first run is the slowest. Later refreshes only fetch new commits."
            )
            .frame(minHeight: UIScale.pt(240))
        case .setup:
            CodeStatsSetupView(model: model)
        case .unavailable:
            PageEmptyState(
                icon: .chartBar, title: "Your results could not be opened",
                message:
                    "The sync finished, but Code Stats could not read its saved results. Try again, or refresh to rebuild them.",
                primary: PageAction("Try again", icon: .refresh) {
                    Task { await model.loadReport() }
                },
                secondary: PageAction("Refresh from GitHub", icon: .cloudDownload) {
                    Task { await model.start() }
                }
            )
            .pageFillViewport()
        case .content:
            if model.table == nil {
                WrapHStack(
                    spacing: UIScale.pt(PageMetrics.controlSpacing),
                    lineSpacing: UIScale.pt(PageMetrics.controlSpacing)
                ) {
                    CodeStatsDateFilter(model: model)
                }
            }
            if model.reportIsEmpty {
                if model.table == nil {
                    noCommits.frame(minHeight: UIScale.pt(220))
                } else {
                    noCommits.pageFillViewport()
                }
            } else if let report = model.report {
                sections(report)
                    .environment(\.codeStatsActions, actions)
            }
        }
    }

    private var noCommits: some View {
        PageEmptyState(
            icon: .search, title: "No commits in this range",
            message: model.hasActiveFilter
                ? "Nothing matches your current filters. Clear them or pick a longer range."
                : "No commits by you were found here. Try a longer range, or check that your name or email is listed under Settings.",
            primary: model.hasActiveFilter
                ? PageAction("Clear filters", icon: .filter) {
                    Task { await model.updateFilter { $0 = .default } }
                }
                : PageAction("Show all time", icon: .calendar) {
                    Task { await model.select(.preset(.allTime)) }
                }
        )
    }

    private var actions: CodeStatsActions {
        CodeStatsActions(
            toggleRepository: { name in Task { await model.toggleRepository(name) } },
            excludeRepository: { name in Task { await model.toggleExcludedRepository(name) } },
            toggleLanguage: { name in Task { await model.toggleLanguage(name) } },
            toggleOwner: { name in Task { await model.toggleOwner(name) } },
            zoom: { start, end in Task { await model.zoom(from: start, to: end) } },
            dayDetails: model.explorer.days,
            selectedRepositories: model.filter.repositories,
            selectedLanguages: model.filter.languages)
    }

    private func sections(_ report: CodeStatsReport) -> some View {
        LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            CodeStatsReportSections(report: report, projection: model.projection, dark: dark)
            if model.table != nil {
                if model.explorer.stripMonths.count >= CodeStatsExplorer.stripMinimumMonths {
                    CodeStatsRepositoryStripCard(explorer: model.explorer, dark: dark)
                }
                CodeStatsShareCard(explorer: model.explorer, dark: dark)
                CodeStatsYearOverYearCard(explorer: model.explorer, dark: dark)
                if !model.projection.isSingleDay {
                    CodeStatsRhythmCard(explorer: model.explorer, dark: dark)
                }
                CodeStatsNewRepositoriesCard(explorer: model.explorer, dark: dark)
            }
            if let audit = model.audit {
                CodeStatsAuditCard(audit: audit, model: model, dark: dark)
                CodeStatsHygieneCard(audit: audit, model: model, dark: dark)
            }
            if model.table != nil {
                CodeStatsLargestCommitsCard(commits: model.largest, dark: dark)
            }
        }
    }

    private func chooseFolder() {
        guard CodeStatsExecutionEnvironment.fixtureHome == nil else { return }
        CodeStatsFolderPanel.choose(for: model)
    }
}

struct CodeStatsReportSections: View {
    let report: CodeStatsReport
    let projection: CodeStatsProjection
    let dark: Bool

    var body: some View {
        LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            CodeStatsKPIGrid(report: report, dark: dark)
            if !projection.showsContributions {
                if !projection.isSingleDay {
                    CodeStatsTopDaysCard(days: projection.topDays, dark: dark)
                }
            } else if sharesActivityRow {
                CodeStatsActivityRow(projection: projection, dark: dark)
            } else {
                CodeStatsHeatmapCard(weeks: projection.heatWeeks, dark: dark)
            }
            CodeStatsTrendCard(projection: projection, dark: dark)
            CodeStatsRepositoryCards(projection: projection, dark: dark)
            CodeStatsLanguageCards(projection: projection, dark: dark)
            if !projection.isSingleDay {
                CodeStatsHabitCards(
                    projection: projection, dark: dark,
                    showsTopDays: projection.showsContributions && !sharesActivityRow)
            }
        }
    }

    private var sharesActivityRow: Bool {
        projection.heatWeeks.count <= CodeStatsActivityRow.sharedRowWeeks
    }
}
