import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DashboardView: View {
    @Environment(\.usageUIClient) private var client
    @State private var refresh: DashboardRefreshBridge
    @State private var model: DashboardModel
    private let presenterState: UsagePresenterState
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.Presenter.blurMoney, store: SharedDefaults.store) private
        var presenterBlurMoney =
        true
    @AppStorage(AppStorageKeys.Presenter.blurUsage, store: SharedDefaults.store) private
        var presenterBlurUsage =
        false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.compactLayout) private var compactLayout
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled
    @State private var showLog = false
    @State private var showMoreMetrics = false
    @State private var folderPickerOpen = false
    @State private var sourcePickerOpen = false
    @State private var modelPickerOpen = false
    @State private var machinePickerOpen = false
    @State private var sharePresentation: ExportCardPresentation<UsageExportDeck>?

    private var appTheme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var acc: Color { DashSkin.accent(dark) }
    private var gold: Color { DashSkin.gold }
    private var blurMoney: Bool { presenterState.active && presenterState.money }
    private var blurUsage: Bool { presenterState.active && presenterState.usage }

    @MainActor init(
        model: DashboardModel? = nil, client: UsageUIClient? = nil,
        presenter: UsagePresenterState? = nil
    ) {
        _model = State(initialValue: model ?? DashboardModel.shared)
        presenterState = presenter ?? UsagePresenterState.shared
        _refresh = State(
            initialValue: DashboardRefreshBridge(
                uiClient: client,
                requestUsageRefresh: {
                    if let client {
                        client.perform("usage.refresh")
                    } else {
                        _ = try? UsageWorkerOperations.requestRefresh()
                    }
                }))
    }

    private static let firstRunSteps = [
        PageGuideStep(
            icon: .folder, title: "Collect",
            detail: "Edith reads your agents' local history. This runs on your Mac."),
        PageGuideStep(
            icon: .chartBar, title: "Explore",
            detail: "See cost and tokens by day, model, project and machine."),
        PageGuideStep(
            icon: .gauge, title: "Watch your limits",
            detail: "Track how much of each plan's allowance you have used."),
    ]

    private var emptyState: UsageEmptyState {
        UsageEmptyState.resolve(
            state: model.contentLoad.state, loaded: model.loaded, updating: refresh.updating,
            errorMessage: model.contentLoad.errorMessage)
    }

    private var emptyStateFillsPage: Bool {
        !showLog && client?.notice == nil && client?.failure == nil
            && UsageWorkerOperations.controller?.notice == nil
    }

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            masthead
        } content: {
            if showLog { logView }
            if let notice = client?.notice
                ?? UsageWorkerOperations.controller?.notice
            {
                PageNotice(notice, tone: .information)
            }
            if let failure = client?.failure {
                PageNotice(
                    failure, tone: .error,
                    actions: { Button("Retry", action: refresh.requestRefresh) })
            }
            if model.loaded, let error = model.contentLoad.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry", action: refresh.requestRefresh)
                    })
            }
            switch emptyState {
            case .collecting:
                PageEmptyState(
                    icon: .chartBar,
                    title: "Collecting your usage",
                    message:
                        "Edith is reading the history your coding agents keep on this Mac. The first collection can take a few minutes, and the dashboard fills in as soon as it finishes.",
                    secondary: PageAction("Watch the log", icon: .terminal) {
                        withAnimation(.easeOut(duration: 0.15)) { showLog = true }
                    },
                    footnote:
                        "Only token counts and model names are read. Your prompts and code stay where they are."
                )
                .fillingPage(emptyStateFillsPage)
            case .firstRun:
                PageEmptyState(
                    icon: .usage,
                    title: "See what your coding agents cost",
                    message:
                        "Agent Usage adds up the tokens, cost and rate limits from agents like Claude Code and Codex, all from files already on this Mac.",
                    steps: Self.firstRunSteps,
                    primary: PageAction("Collect usage now", icon: .refresh) {
                        refresh.requestRefresh()
                    },
                    secondary: PageAction("Show the log", icon: .terminal) {
                        withAnimation(.easeOut(duration: 0.15)) { showLog = true }
                    },
                    footnote:
                        "Nothing is uploaded and nothing is changed. If you have not used an agent yet, there is nothing to count until you do."
                )
                .fillingPage(emptyStateFillsPage)
            case .failed(let message):
                PageEmptyState(
                    icon: .warning,
                    title: "Usage could not be read",
                    message:
                        "\(message) Your usage files were not changed. Collecting again usually fixes this.",
                    primary: PageAction("Collect again", icon: .refresh) {
                        refresh.requestRefresh()
                    },
                    secondary: PageAction("Show the log", icon: .terminal) {
                        withAnimation(.easeOut(duration: 0.15)) { showLog = true }
                    }
                )
                .fillingPage(emptyStateFillsPage)
            case .none:
                PageLoading(
                    state: model.contentLoad.state, title: "No usage data yet",
                    errorTitle: "Usage could not be read",
                    message: model.contentLoad.errorMessage ?? "Collect usage to fill this page.",
                    layout: .analytics,
                    refreshing: model.contentLoad.isRefreshing || model.computation.isRunning,
                    retry: refresh.requestRefresh
                ) {
                    kpiGrid
                    activityRow(compact: compactLayout)
                    LimitsCardView(theme: acc, dark: dark)
                    BudgetCardView(theme: acc, dark: dark)
                    charts(compact: compactLayout)
                }
            }
        }
        .exportCardPresentation(item: $sharePresentation)
        .navigationTitle("Agent Usage")
        .pageTask(id: refresh.updating) {
            await model.load()
        }
        .pageTask {
            refresh.requestRefresh()
        }
        .pageTask {
            for await _ in NotificationCenter.default.notifications(named: UsageEvents.usageUpdated)
            {
                guard !Task.isCancelled else { return }
                await model.load()
            }
        }
        .pageTask(cancel: model.endObserving) {
            model.beginObserving()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        ) { _ in
            guard automaticActionsEnabled else { return }
            model.reloadPreferences()
        }
        .onChange(of: automaticActionsEnabled) { _, enabled in
            if !enabled { refresh.setLogVisible(false) }
        }
        .onChange(of: showLog) { _, shown in
            refresh.setLogVisible(shown)
        }
    }

    private var masthead: some View {
        PageHeader(subtitle: headerSubtitle, divider: true) {
            Text("Agent usage")
        } trailing: {
            mastheadButtons
        } accessory: {
            if model.loaded { filterBar }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent usage")
    }

    private var headerSubtitle: String {
        guard model.loaded else {
            return "Tokens, cost and rate limits from your coding agents, collected on this Mac."
        }
        return Self.metaSummary(
            updated: model.meta.updated, activeDays: model.meta.activeDays,
            sources: sourceMetaText)
    }

    static func metaSummary(updated: String, activeDays: Int, sources: String) -> String {
        [
            updated.isEmpty ? nil : "Updated \(updated)",
            activeDays == 1 ? "1 active day" : "\(activeDays) active days",
            sources.isEmpty ? nil : sources,
        ]
        .compactMap { $0 }
        .joined(separator: " \u{00B7} ")
    }

    private var mastheadButtons: some View {
        HStack(spacing: UIScale.pt(6)) {
            PageToolbarButton(
                action: refresh.requestRefresh,
                icon: .refresh,
                helperText: "Collect new usage now",
                isLoading: refresh.updating
            )
            PageToolbarButton(
                action: { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } },
                icon: .terminal,
                helperText: showLog ? "Hide the collector log" : "Show the collector log",
                tint: showLog ? appTheme : DashSkin.inkFaint(dark)
            )
            ExportCardButton(isEnabled: model.loaded, help: "Share usage cards") {
                sharePresentation = ExportCardPresentation(
                    deck: UsageExportDeck(
                        snapshot: shareSnapshot,
                        delivery: { data, filename, save in
                            guard let client = client else {
                                throw ExtensionPeerError.unavailable
                            }
                            return try await client.deliverExport(
                                data, filename: filename, save: save)
                        }), title: "Share usage cards")
            }
        }
    }

    private var shareSnapshot: UsageShareSnapshot {
        let details = model.heatDetail.sorted { $0.key < $1.key }
        let agents = Set(details.flatMap { $0.value.sources.map(\.id) })
        let repositories = Set(
            details.flatMap { $0.value.projects.map(\.id) }.filter { $0 != "unattributed" })
        return UsageShareSnapshot(
            days: details.map { period, detail in
                UsageShareDay(period: period, tokens: detail.tokens, cost: detail.cost)
            },
            agentCount: agents.count, repositoryCount: repositories.count,
            generatedAt: model.meta.updated)
    }

    private var sourceMetaText: String {
        model.allSources.count > 3 ? "\(model.allSources.count) agents" : model.meta.sourceLabels
    }

    private var kpiGrid: some View {
        VStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            metricGrid(Array(model.kpis.prefix(4)))
            if model.kpis.count > 4 {
                if showMoreMetrics {
                    metricGrid(Array(model.kpis.dropFirst(4)))
                }
                Button {
                    withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
                        showMoreMetrics.toggle()
                    }
                } label: {
                    HStack(spacing: UIScale.pt(4)) {
                        Text(
                            showMoreMetrics
                                ? "Show fewer metrics"
                                : "Show \(model.kpis.count - 4) more metrics")
                        EdithIconView(.chevronDown)
                            .font(.system(size: UIScale.pt(9), weight: .semibold))
                            .rotationEffect(.degrees(showMoreMetrics ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.edith(.borderless))
                .font(.edithText(.callout).weight(.medium))
                .foregroundStyle(acc)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metricGrid(_ metrics: [KPI]) -> some View {
        PageMetricGrid(maximumColumns: 4) {
            ForEach(metrics) { kpi in
                PageMetric(
                    title: kpi.label, value: kpi.value, detail: kpi.sub,
                    valueBlurred: (kpi.sensitiveValue && blurMoney)
                        || (kpi.usageValue && blurUsage),
                    detailBlurred: (kpi.sensitiveSub && blurMoney) || (kpi.usageSub && blurUsage))
            }
        }
    }

    @ViewBuilder private func activityRow(compact: Bool) -> some View {
        if compact {
            VStack(spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                PageCard(title: "Activity") { activityHeatmap }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("usage-activity")
                RateLimitsDialsView(dark: dark)
            }
        } else {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                PageCard(title: "Activity", fill: true) { activityHeatmap }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("usage-activity")
                RateLimitsDialsView(dark: dark, fill: true).frame(width: UIScale.pt(340))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activityHeatmap: some View {
        let summary = UsageActivitySummary.make(days: model.calendarDays)
        let heatmap = ActivityHeatmap(
            days: model.calendarDays, scale: model.chartData.heatScale,
            model: model, dark: dark, blur: blurMoney, blurTokens: blurUsage
        )
        return Group {
            if compactLayout {
                VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    heatmap.frame(maxWidth: .infinity, alignment: .leading)
                    UsageActivitySummaryView(
                        summary: summary, axis: .horizontal, blurTokens: blurUsage)
                }
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(24)) {
                    heatmap.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(DashSkin.line(dark)).frame(width: 1)
                    UsageActivitySummaryView(
                        summary: summary, axis: .vertical, blurTokens: blurUsage
                    )
                    .frame(width: UIScale.pt(156), alignment: .leading)
                }
            }
        }
    }

    private var filterBar: some View {
        PageFilterBar {
            PageFilterRow("Range") {
                PageDateFilter(
                    selection: $model.range, months: model.dateFilterMonths,
                    earliest: model.earliestDay)
            }
            PageFilterRow("Scope") {
                if !model.machineGroups.isEmpty { machineMenu }
                modelMenu
                projectMenu
                sourceMenu
                if !filtersAreDefault { resetButton }
            }
        }
    }

    private var filtersAreDefault: Bool {
        model.range == .preset(.allTime) && model.selectedPaths.isEmpty
            && model.selectedSources == Set(model.defaultSources)
            && model.selectedModels == Set(model.defaultModels)
    }

    private var resetButton: some View {
        Button("Reset filters") { model.reset() }
            .buttonStyle(.edith(.borderless))
            .font(PageMetrics.chipFont)
            .foregroundStyle(acc)
            .frame(minHeight: UIScale.pt(PageMetrics.chipHeight))
            .fixedSize()
            .help("Show every agent, model and folder for all time")
    }

    private var projectMenu: some View {
        Button {
            folderPickerOpen = true
        } label: {
            PageChipLabel(folderScopeLabel, icon: .folder, menu: true)
        }
        .buttonStyle(.pageChip(active: !model.selectedPaths.isEmpty)).fixedSize()
        .popover(isPresented: $folderPickerOpen, arrowEdge: .bottom) {
            FolderScopePicker(model: model, dark: dark) { folderPickerOpen = false }
        }
    }

    private var folderScopeLabel: String {
        let paths = model.selectedPaths
        if paths.isEmpty { return "All folders" }
        if paths.count == 1, let path = paths.first {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.count > 18 ? String(name.prefix(17)) + "…" : name
        }
        return "\(paths.count) folders"
    }

    private var sourceMenu: some View {
        Button {
            sourcePickerOpen = true
        } label: {
            PageChipLabel(sourceSummary, icon: .layers, menu: true)
        }
        .buttonStyle(.pageChip(active: model.selectedSources.count != model.allSources.count))
        .fixedSize()
        .popover(isPresented: $sourcePickerOpen, arrowEdge: .bottom) {
            FilterMultiSelect(
                options: model.allSources.map { FilterSelectOption(id: $0.id, label: $0.label) },
                selection: $model.selectedSources, dark: dark
            ) { sourcePickerOpen = false }
        }
    }

    private var sourceSummary: String {
        if model.selectedSources.count == model.allSources.count { return "All agents" }
        if model.selectedSources.count == 1, let id = model.selectedSources.first {
            return model.sourceLabel(id)
        }
        return "\(model.selectedSources.count) agents"
    }

    private var machineMenu: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let stale = selectedStaleMachines(now: timeline.date)
            Button {
                machinePickerOpen = true
            } label: {
                PageChipLabel(
                    machineSummary(now: timeline.date),
                    icon: stale.isEmpty ? .server : .warning,
                    menu: true)
            }
            .buttonStyle(
                .pageChip(
                    active: !stale.isEmpty || !allMachinesShown,
                    tint: stale.isEmpty ? nil : .orange)
            )
            .fixedSize()
        }
        .popover(isPresented: $machinePickerOpen, arrowEdge: .bottom) {
            UsageMachinesPicker(model: model, dark: dark) { machinePickerOpen = false }
        }
    }

    private func machineSummary(now: Date) -> String {
        let groups = model.machineGroups
        guard !groups.isEmpty else { return "Machines" }
        let stale = selectedStaleMachines(now: now)
        if stale.count == 1, let item = stale.first {
            return item.freshness.isStale
                ? "\(item.group.name) stale \(item.freshness.ageLabel)"
                : "\(item.group.name) refresh failed"
        }
        if stale.count > 1 { return "\(stale.count) machines need attention" }
        let shown = groups.filter { model.machineIsShown($0) || model.machineIsPartlyShown($0) }
        if shown.count == groups.count { return "All machines" }
        if shown.count == 1, let only = shown.first { return only.name }
        return "\(shown.count) of \(groups.count) machines"
    }

    private var allMachinesShown: Bool {
        model.machineGroups.allSatisfy { model.machineIsShown($0) }
    }

    private func selectedStaleMachines(now: Date) -> [(
        group: MachineGroup, freshness: MachineUsageFreshness
    )] {
        model.machineGroups.compactMap { group in
            guard model.machineIsShown(group) || model.machineIsPartlyShown(group),
                let freshness = model.machineFreshness(group, now: now), freshness.needsAttention
            else { return nil }
            return (group, freshness)
        }
    }

    private var modelMenu: some View {
        Button {
            modelPickerOpen = true
        } label: {
            PageChipLabel(modelSummary, icon: .cpu, menu: true)
        }
        .buttonStyle(.pageChip(active: model.selectedModels.count != model.allModels.count))
        .fixedSize()
        .popover(isPresented: $modelPickerOpen, arrowEdge: .bottom) {
            FilterMultiSelect(
                options: model.allModels.map {
                    FilterSelectOption(id: $0, label: DashFmt.shortModel($0))
                },
                selection: $model.selectedModels, dark: dark
            ) { modelPickerOpen = false }
        }
    }

    private var modelSummary: String {
        let count = model.selectedModels.count
        if count == model.allModels.count { return "All models" }
        if count == 1, let only = model.selectedModels.first { return DashFmt.shortModel(only) }
        return "\(count) models"
    }

    private var logView: some View {
        TerminalLogView(log: refresh.log, theme: appTheme, height: UIScale.pt(150))
    }

    private func charts(compact: Bool) -> some View {
        LazyVStack(spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
            LazyChartCard(title: "Daily usage", dark: dark) {
                ComboChart(
                    points: model.chartData.daily, barColor: acc, lineColor: gold, dark: dark,
                    scroll: true, blur: blurMoney, blurTokens: blurUsage)
            }
            LazyChartCard(title: "Token mix by day", dark: dark) {
                StackedChart(
                    bars: model.chartData.tokenMix, costLine: model.chartData.stackedCost,
                    domain: tokenMixDomain, range: tokenMixRange, dark: dark, blur: blurMoney,
                    blurTokens: blurUsage)
            }
            LazyChartCard(title: "Model usage over time", dark: dark) {
                StackedChart(
                    bars: model.chartData.modelTime, costLine: model.chartData.stackedCost,
                    domain: modelDomain, range: modelRange, dark: dark, blur: blurMoney,
                    blurTokens: blurUsage)
            }
            if model.allSources.count > 1 {
                LazyChartCard(title: "Usage by source over time", dark: dark) {
                    StackedChart(
                        bars: model.chartData.source, costLine: model.chartData.stackedCost,
                        domain: sourceDomain, range: sourceRange, dark: dark, blur: blurMoney,
                        blurTokens: blurUsage)
                }
            }
            if compact {
                VStack(spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    dowCard
                    shareByModelCard
                }
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                    dowCard
                    shareByModelCard
                }
            }
            if !model.projects.isEmpty || !pathUnattributedText.isEmpty {
                LazyChartCard(
                    title: "By project", dark: dark, placeholderHeight: UIScale.pt(304)
                ) {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        if !model.projects.isEmpty {
                            ComboChart(
                                points: model.chartData.project, barColor: acc, lineColor: gold,
                                dark: dark, height: UIScale.pt(280), blur: blurMoney,
                                blurTokens: blurUsage)
                            ProjectDrilldownView(
                                model: model, dark: dark, blur: blurMoney, blurTokens: blurUsage)
                        }
                        if !pathUnattributedText.isEmpty {
                            Text(pathUnattributedText)
                                .font(.edithText(.caption))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                                .presenterBlur(blurMoney || blurUsage)
                        }
                    }
                }
            }
            LazyChartCard(title: "Hourly usage", dark: dark) {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    ComboChart(
                        points: model.chartData.hourly, barColor: acc, lineColor: gold, dark: dark,
                        height: UIScale.pt(200), blur: blurMoney, blurTokens: blurUsage)
                    if !hourlyUnattributedText.isEmpty {
                        Text(hourlyUnattributedText)
                            .font(.edithText(.caption))
                            .foregroundStyle(DashSkin.inkSoft(dark))
                            .presenterBlur(blurMoney || blurUsage)
                    }
                }
            }
            PageCard(
                title: "Models", note: "\(model.modelTotals.count) total"
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    if model.modelUnfilterableCost > 0.000_001 {
                        Text(
                            "Unattributed provider cost of \(DashFmt.usd(model.modelUnfilterableCost)) is excluded because it spans selected and unselected models."
                        )
                        .font(.edithText(.caption))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .presenterBlur(blurMoney)
                    }
                    modelsTable
                }
            }
        }
        .background(ChartWarmup())
    }

    private var hourlyUnattributedText: String {
        let tokens = model.hourlyUnattributedTokens
        let cost = model.hourlyUnattributedCost
        if tokens > 0.000_001, cost > 0.000_001 {
            let tokenText = DashFmt.tokens(tokens)
            return "Hourly detail is unavailable for \(tokenText) tokens and \(DashFmt.usd(cost))."
        }
        if tokens > 0.000_001 {
            return "Hourly detail is unavailable for \(DashFmt.tokens(tokens)) tokens."
        }
        if cost > 0.000_001 {
            return "Hourly detail is unavailable for \(DashFmt.usd(cost))."
        }
        return ""
    }

    private var pathUnattributedText: String {
        let tokens = model.pathUnattributedTokens
        let cost = model.pathUnattributedCost
        if tokens > 0.000_001, cost > 0.000_001 {
            return
                "Folder detail is unavailable for \(DashFmt.tokens(tokens)) tokens and \(DashFmt.usd(cost)), so it is excluded from this folder view."
        }
        if tokens > 0.000_001 {
            return
                "Folder detail is unavailable for \(DashFmt.tokens(tokens)) tokens, so it is excluded from this folder view."
        }
        if cost > 0.000_001 {
            return
                "Folder detail is unavailable for \(DashFmt.usd(cost)), so it is excluded from this folder view."
        }
        return ""
    }

    private var dowCard: some View {
        LazyChartCard(title: "By day of week", dark: dark) {
            ComboChart(
                points: model.chartData.dow, barColor: acc, lineColor: gold, dark: dark,
                height: UIScale.pt(200), blur: blurMoney, blurTokens: blurUsage)
        }
    }

    private var shareByModelCard: some View {
        LazyChartCard(title: "Share by model", dark: dark) {
            DonutChart(slices: donutSlices, blurTokens: blurUsage)
        }
    }

    private var modelsTable: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack(spacing: UIScale.pt(8)) {
                tableHeader("Model", .model, width: nil)
                tableHeader("Cost", .cost, width: UIScale.pt(70))
                if !compactLayout {
                    tableHeader("Share", .share, width: UIScale.pt(60))
                }
                tableHeader("Tokens", .tokens, width: UIScale.pt(70))
                if !compactLayout {
                    tableHeader("Days", .days, width: UIScale.pt(44))
                }
            }
            .pageCapsStyle()
            .padding(.vertical, UIScale.pt(4))
            Rectangle().fill(DashSkin.line(dark)).frame(height: UIScale.pt(1))
            if model.modelTotals.count > DashboardChartLayout.visibleModelRows {
                ScrollView {
                    LazyVStack(spacing: UIScale.pt(0)) {
                        modelRows
                    }
                }
                .frame(
                    height: UIScale.pt(
                        DashboardChartLayout.modelRowHeight
                            * CGFloat(DashboardChartLayout.visibleModelRows)))
            } else {
                VStack(spacing: UIScale.pt(0)) {
                    modelRows
                }
            }
        }
    }

    @ViewBuilder private var modelRows: some View {
        ForEach(model.modelTotals) { m in
            HStack(spacing: UIScale.pt(8)) {
                Circle().fill(model.modelColor(m.model, dark: dark)).frame(
                    width: UIScale.pt(8), height: UIScale.pt(8))
                Text(model.modelLabel(m.model))
                    .font(.edithText(.callout)).foregroundStyle(DashSkin.ink(dark))
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                Text(DashFmt.usd(m.cost)).font(.edithText(.callout).monospacedDigit()).frame(
                    width: UIScale.pt(70), alignment: .trailing
                ).presenterBlur(blurMoney)
                if !compactLayout {
                    Text(DashFmt.pct(m.share)).font(.edithText(.callout).monospacedDigit()).frame(
                        width: UIScale.pt(60), alignment: .trailing
                    ).foregroundStyle(DashSkin.inkSoft(dark))
                }
                Text(DashFmt.tokens(m.tokens)).font(.edithText(.callout).monospacedDigit()).frame(
                    width: UIScale.pt(70), alignment: .trailing
                ).presenterBlur(blurUsage)
                if !compactLayout {
                    Text("\(m.days)").font(.edithText(.callout).monospacedDigit()).frame(
                        width: UIScale.pt(44), alignment: .trailing
                    )
                    .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
            .foregroundStyle(DashSkin.ink(dark))
            .padding(.vertical, UIScale.pt(5))
            Rectangle().fill(DashSkin.line(dark).opacity(0.5)).frame(height: UIScale.pt(1))
        }
    }

    private func tableHeader(_ title: String, _ col: TableColumn, width: CGFloat?) -> some View {
        Button {
            if model.sortColumn == col {
                model.sortAscending.toggle()
            } else {
                model.sortColumn = col
                model.sortAscending = false
            }
        } label: {
            HStack(spacing: UIScale.pt(2)) {
                Text(title)
                if model.sortColumn == col {
                    EdithIconView(model.sortAscending ? .chevronUp : .chevronDown)
                        .font(.system(size: UIScale.pt(8), weight: .semibold))
                }
            }
            .frame(width: width, alignment: width == nil ? .leading : .trailing)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        }
        .buttonStyle(.edith(.borderless))
    }

    private var tokenMixDomain: [String] { ["input", "output", "cache write", "cache read"] }
    private var tokenMixRange: [Color] {
        [
            DashPalette.inputColor(dark), DashPalette.outputColor(dark),
            DashPalette.cacheCreateColor, DashPalette.cacheReadColor,
        ]
    }
    private var modelDomain: [String] { chartSeriesDomain(model.chartData.modelTime) }
    private var modelRange: [Color] {
        modelDomain.map { series in
            guard series != "Other",
                let name = model.allModels.first(where: { DashFmt.shortModel($0) == series })
            else { return DashSkin.inkFaint(dark) }
            return model.modelColor(name, dark: dark)
        }
    }
    private var sourceDomain: [String] { chartSeriesDomain(model.chartData.source) }
    private var sourceRange: [Color] {
        sourceDomain.map { series in
            guard series != "Other",
                let source = model.allSources.first(where: { $0.label == series })
            else { return DashSkin.inkFaint(dark) }
            return model.sourceColor(source.id, dark: dark)
        }
    }
    private var donutSlices: [DonutSlice] {
        let slices = model.tokenBearingModelTotals.map {
            DonutSlice(
                id: $0.model, label: model.modelLabel($0.model), value: $0.tokens,
                color: model.modelColor($0.model, dark: dark))
        }
        return compactDonutSlices(slices, otherColor: DashSkin.inkFaint(dark))
    }
}

struct ActivityHeatmap: View {
    let days: [DayPoint]
    let scale: UsageCalendarScale
    let model: DashboardModel
    let dark: Bool
    var blur = false
    var blurTokens = false
    var body: some View {
        ActivityCalendarGrid(
            weeks: scale.weeks(days: days), dark: dark, fillsWidth: true
        ) { day in
            if let detail = model.heatDetail[day.id] {
                HeatCard(
                    detail: detail, model: model, dark: dark, blur: blur, blurTokens: blurTokens)
            } else {
                Text("No usage on this day.")
                    .font(.edithText(.callout))
                    .padding(UIScale.pt(12))
            }
        }
    }
}

extension View {
    @ViewBuilder fileprivate func fillingPage(_ fills: Bool) -> some View {
        if fills { pageFillViewport() } else { self }
    }
}
