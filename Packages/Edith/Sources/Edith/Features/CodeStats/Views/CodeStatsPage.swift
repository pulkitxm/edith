import AppKit
import EdithKit
import SwiftUI

struct CodeStatsPage: View {
    @State private var model: CodeStatsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    init(model: CodeStatsModel? = nil) {
        _model = State(initialValue: model ?? .shared)
    }

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                CodeStatsHeader(model: model)
                Group {
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
                    content
                }
                .pageGutter(compact)
            }
            .padding(.bottom, UIScale.pt(PageMetrics.bottom))
        }
        .background(DashSkin.paper(dark))
        .task {
            guard automaticActionsEnabled else { return }
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
            CodeStatsReportSkeleton(dark: dark)
        case .setup:
            CodeStatsSetupView(model: model, choose: chooseFolder)
        case .unavailable:
            EmptyView()
        case .content:
            CodeStatsRangePicker(range: model.range) { range in
                Task { await model.select(range) }
            }
            if let report = model.report {
                if model.showsPreviousRange {
                    SkeletonReplica("Loading \(CodeStatsRangePicker.title(model.range))") {
                        CodeStatsReportSections(
                            report: report, projection: model.projection, dark: dark)
                    }
                } else {
                    CodeStatsReportSections(
                        report: report, projection: model.projection, dark: dark)
                }
            }
        }
    }

    private func chooseFolder() {
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
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            CodeStatsKPIGrid(report: report, dark: dark)
            CodeStatsHeatmapCard(weeks: projection.heatWeeks, dark: dark)
            CodeStatsTrendCard(projection: projection, dark: dark)
            CodeStatsRepositoryCards(projection: projection, dark: dark)
            CodeStatsLanguageCards(projection: projection, dark: dark)
            CodeStatsHabitCards(projection: projection, dark: dark)
        }
    }
}
