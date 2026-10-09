import AppKit
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
        PageScaffold(pinnedHeader: true) {
            VStack(spacing: 0) {
                CodeStatsHeader(model: model)
                if model.table != nil {
                    CodeStatsFilterBar(model: model, dark: dark)
                        .pageGutter(compact)
                        .padding(.bottom, UIScale.pt(12))
                }
                Divider()
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
                layout: .analytics, refreshing: model.isRefreshing,
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
        case .loading, .firstRun:
            EmptyView()
        case .setup:
            CodeStatsSetupView(model: model, choose: chooseFolder)
        case .unavailable:
            EmptyView()
        case .content:
            if model.table == nil {
                CodeStatsRangePicker(range: model.range) { range in
                    Task { await model.select(range) }
                }
            }
            if let report = model.report {
                sections(report)
                    .environment(\.codeStatsActions, actions)
            }
        }
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
                CodeStatsRepositoryStripCard(explorer: model.explorer, dark: dark)
                CodeStatsShareCard(explorer: model.explorer, dark: dark)
                CodeStatsYearOverYearCard(explorer: model.explorer, dark: dark)
                CodeStatsRhythmCard(explorer: model.explorer, dark: dark)
                CodeStatsNewRepositoriesCard(explorer: model.explorer, dark: dark)
            }
            if let audit = model.audit {
                CodeStatsAuditCard(audit: audit, model: model, dark: dark)
                CodeStatsHygieneCard(audit: audit, model: model, dark: dark)
            }
            if let table = model.table {
                CodeStatsLargestCommitsCard(commits: table.largest, dark: dark)
            }
        }
    }

    private func chooseFolder() {
        guard CodeStatsExecutionEnvironment.fixtureHome == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for your GitHub mirror"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.chooseFolder(url.path) }
    }
}

struct CodeStatsReportSections: View {
    let report: CodeStatsReport
    let projection: CodeStatsProjection
    let dark: Bool

    var body: some View {
        LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            CodeStatsKPIGrid(report: report, dark: dark)
            CodeStatsHeatmapCard(weeks: projection.heatWeeks, dark: dark)
            CodeStatsTrendCard(projection: projection, dark: dark)
            CodeStatsRepositoryCards(projection: projection, dark: dark)
            CodeStatsLanguageCards(projection: projection, dark: dark)
            CodeStatsHabitCards(projection: projection, dark: dark)
        }
    }
}
