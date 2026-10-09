import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct DashboardView: View {
    @State private var refresh = DashboardRefreshBridge()
    @State private var model: DashboardModel
    private var presenterState = UsagePresenterState.shared
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
    @State private var folderPickerOpen = false
    @State private var sourcePickerOpen = false
    @State private var modelPickerOpen = false
    @State private var machinePickerOpen = false
    @State private var customRangeOpen = false
    @State private var sharePresentation: ExportCardPresentation<UsageExportDeck>?
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private var appTheme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var acc: Color { DashSkin.accent(dark) }
    private var gold: Color { DashSkin.gold }
    private var blurMoney: Bool { presenterState.active && presenterState.money }
    private var blurUsage: Bool { presenterState.active && presenterState.usage }

    private static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let monthKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let monthName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    @MainActor init(model: DashboardModel? = nil) {
        _model = State(initialValue: model ?? DashboardModel.shared)
    }

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            VStack(spacing: 0) {
                masthead
                if model.loaded {
                    controlsBar.pageGutter(compactLayout)
                        .padding(.bottom, UIScale.pt(12))
                }
                Divider()
            }
        } content: {
            if showLog { logView }
            if model.loaded, let error = model.contentLoad.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry", action: refresh.requestRefresh)
                    })
            }
            PageLoading(
                state: model.contentLoad.state, title: "No usage data yet",
                message: model.contentLoad.errorMessage ?? "Reload to run the bundled collector.",
                layout: .analytics,
                refreshing: model.contentLoad.isRefreshing || model.computation.isRunning,
                retry: refresh.requestRefresh
            ) {
                kpiGrid(compact: compactLayout)
                activityRow(compact: compactLayout)
                LimitsCardView(theme: acc, dark: dark)
                BudgetCardView(theme: acc, dark: dark)
                charts(compact: compactLayout)
            }
        }
        .exportCardPresentation(item: $sharePresentation)
        .navigationTitle("Agent Usage")
        .pageTask(id: refresh.updating, active: !refresh.updating) {
            await model.load()
            syncCustomDates()
        }
        .pageTask {
            refresh.requestRefresh()
        }
        .pageTask {
            for await _ in NotificationCenter.default.notifications(named: UsageEvents.usageUpdated)
            {
                guard !Task.isCancelled else { return }
                await model.load()
                syncCustomDates()
            }
        }
        .pageTask(cancel: model.endObserving) {
            model.beginObserving()
        }
        .onChange(of: model.loaded) { _, loaded in
            if automaticActionsEnabled, loaded { syncCustomDates() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
        ) { _ in
            guard automaticActionsEnabled else { return }
            model.reloadPreferences()
            syncCustomDates()
        }
        .onChange(of: showLog) { _, shown in
            refresh.setLogVisible(shown)
        }
    }

    private var masthead: some View {
        PageHeader {
            Text("Agent usage")
        } trailing: {
            mastheadButtons
        } accessory: {
            if model.loaded {
                WrapHStack(spacing: UIScale.pt(6), lineSpacing: 2) {
                    ForEach(metaSegments) { seg in
                        Text(seg.text)
                            .presenterBlur((seg.sensitive && blurMoney) || (seg.usage && blurUsage))
                    }
                }
                .font(.system(size: UIScale.pt(12.5))).foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
    }

    private var mastheadButtons: some View {
        HStack(spacing: UIScale.pt(6)) {
            PageToolbarButton(
                action: refresh.requestRefresh,
                systemImage: "arrow.clockwise",
                helperText: "Refresh usage data",
                isLoading: refresh.updating
            )
            PageToolbarButton(
                action: { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } },
                systemImage: "terminal",
                helperText: "Show collector log",
                tint: showLog ? appTheme : DashSkin.inkFaint(dark)
            )
            ExportCardButton(isEnabled: model.loaded, help: "Share usage cards") {
                sharePresentation = ExportCardPresentation(
                    deck: UsageExportDeck(snapshot: shareSnapshot), title: "Share usage cards")
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

    private struct MetaSegment: Identifiable {
        let id: Int
        let text: String
        let sensitive: Bool
        var usage = false
    }

    private var metaSegments: [MetaSegment] {
        guard model.loaded else { return [MetaSegment(id: 0, text: "Loading…", sensitive: false)] }
        let m = model.meta
        let parts: [(String, Bool, Bool)] = [
            ("Updated \(m.updated)", false, false),
            ("\(m.activeDays) active days", false, false),
            (sourceMetaText, false, false),
        ]
        return parts.enumerated().map { index, part in
            MetaSegment(
                id: index, text: index == 0 ? part.0 : "·  \(part.0)", sensitive: part.1,
                usage: part.2)
        }
    }

    private var sourceMetaText: String {
        model.allSources.count > 3 ? "\(model.allSources.count) agents" : model.meta.sourceLabels
    }

    private func kpiGrid(compact: Bool) -> some View {
        VStack(spacing: UIScale.pt(6)) {
            metricGrid(Array(model.kpis.prefix(4)), compact: compact)
            if model.kpis.count > 4 {
                DisclosureGroup("More metrics") {
                    metricGrid(Array(model.kpis.dropFirst(4)), compact: compact)
                }
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .foregroundStyle(.secondary)
                .disclosureGroupStyle(EdithDisclosureGroupStyle())
            }
        }
    }

    private func metricGrid(_ metrics: [KPI], compact: Bool) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: UIScale.pt(12)),
            count: compact ? 2 : 4)
        return LazyVGrid(columns: columns, spacing: UIScale.pt(12)) {
            ForEach(metrics) { kpi in
                HStack(spacing: UIScale.pt(0)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(kpi.label.uppercased())
                            .font(DashSkin.mono(10)).tracking(UIScale.pt(1.4))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(kpi.value)
                            .font(DashSkin.heading(26))
                            .foregroundStyle(DashSkin.ink(dark))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(
                                Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                                value: kpi.value
                            )
                            .presenterBlur(
                                (kpi.sensitiveValue && blurMoney) || (kpi.usageValue && blurUsage))
                        Text(kpi.sub)
                            .font(.system(size: UIScale.pt(11.5))).foregroundStyle(
                                DashSkin.inkSoft(dark)
                            )
                            .contentTransition(.numericText())
                            .animation(
                                Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                                value: kpi.sub
                            )
                            .presenterBlur(
                                (kpi.sensitiveSub && blurMoney) || (kpi.usageSub && blurUsage))
                    }
                    .padding(UIScale.pt(14))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .edithSurface(cornerRadius: 14)
            }
        }
    }

    @ViewBuilder private func activityRow(compact: Bool) -> some View {
        if compact {
            VStack(spacing: UIScale.pt(16)) {
                PageCard(title: "Activity") { activityHeatmap }
                RateLimitsDialsView(dark: dark)
            }
        } else {
            HStack(alignment: .top, spacing: UIScale.pt(16)) {
                PageCard(title: "Activity", fill: true) { activityHeatmap }
                RateLimitsDialsView(dark: dark, fill: true).frame(width: UIScale.pt(340))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activityHeatmap: some View {
        ActivityHeatmap(
            days: model.calendarDays, scale: model.chartData.heatScale,
            model: model, dark: dark, blur: blurMoney, blurTokens: blurUsage
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlsBar: some View {
        ViewThatFits(in: .horizontal) {
            VStack(spacing: UIScale.pt(10)) {
                HStack(spacing: UIScale.pt(8)) {
                    filterSectionLabel("Range")
                    rangePresets
                    Spacer(minLength: UIScale.pt(24))
                    monthArchiveMenu
                    customRange
                    resetButton
                }
                HStack(spacing: UIScale.pt(8)) {
                    filterSectionLabel("Scope")
                    if !model.machineGroups.isEmpty { machineMenu }
                    modelMenu
                    Spacer(minLength: UIScale.pt(24))
                    projectMenu
                    sourceMenu
                }
            }
            regularControlsBar
            compactControlsBar
        }
        .foregroundStyle(DashSkin.inkSoft(dark))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }

    private var regularControlsBar: some View {
        VStack(spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                filterSectionLabel("Range")
                rangeButton("Today", .today)
                rangeButton("This week", .thisWeek)
                if let month = currentMonthOption {
                    rangeButton("This month", .month(month))
                }
                rangeButton("All", .all)
                alternateRangeMenu
                Spacer(minLength: UIScale.pt(8))
                customRange
                resetButton
            }
            HStack(spacing: UIScale.pt(8)) {
                filterSectionLabel("Scope")
                if !model.machineGroups.isEmpty { machineMenu }
                modelMenu
                Spacer(minLength: UIScale.pt(8))
                monthArchiveMenu
                projectMenu
                sourceMenu
            }
        }
    }

    private var compactControlsBar: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            filterSectionLabel("Range")
            WrapHStack(spacing: UIScale.pt(8), lineSpacing: 8) {
                rangePresets
                monthArchiveMenu
                customRange
                resetButton
            }
            filterSectionLabel("Scope")
            WrapHStack(spacing: UIScale.pt(8), lineSpacing: 8) {
                if !model.machineGroups.isEmpty { machineMenu }
                modelMenu
                projectMenu
                sourceMenu
            }
        }
    }

    private var rangePresets: some View {
        Group {
            rangeButton("Today", .today)
            rangeButton("Yesterday", .yesterday)
            rangeButton("This week", .thisWeek)
            rangeButton("Last week", .lastWeek)
            if let month = currentMonthOption {
                rangeButton("This month", .month(month))
            }
            if let month = previousMonthOption {
                rangeButton("Last month", .month(month))
            }
            rangeButton("All", .all)
        }
    }

    private func filterSectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(DashSkin.mono(8, weight: .semibold))
            .tracking(UIScale.pt(1.2))
            .foregroundStyle(DashSkin.inkFaint(dark))
            .frame(width: UIScale.pt(42), alignment: .leading)
    }

    private var monthArchiveMenu: some View {
        Menu {
            ForEach(model.monthOptions, id: \.self) { month in
                Button(monthDisplayName(month)) { model.range = .month(month) }
            }
        } label: {
            Label("Browse months", systemImage: "calendar.badge.clock")
                .font(.system(size: UIScale.pt(11)))
                .modifier(FilterChip(dark: dark))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.monthOptions.isEmpty)
    }

    private var alternateRangeMenu: some View {
        Menu {
            Button("Yesterday") { model.range = .yesterday }
            Button("Last week") { model.range = .lastWeek }
            if let month = previousMonthOption {
                Button("Last month") { model.range = .month(month) }
            }
        } label: {
            Label("More", systemImage: "clock.arrow.circlepath")
                .font(.system(size: UIScale.pt(11)))
                .modifier(FilterChip(dark: dark, active: alternateRangeActive))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var alternateRangeActive: Bool {
        switch model.range {
        case .yesterday, .lastWeek:
            return true
        case .month(let month):
            return month == previousMonthOption
        default:
            return false
        }
    }

    private var resetButton: some View {
        Button("Reset") { model.reset() }
            .buttonStyle(.edith(.borderless))
            .font(DashSkin.mono(11))
            .foregroundStyle(acc)
            .padding(.horizontal, UIScale.pt(6))
            .padding(.vertical, UIScale.pt(5))
    }

    private var customRange: some View {
        Button {
            customRangeOpen = true
        } label: {
            Label(customRangeLabel, systemImage: "calendar")
                .font(.system(size: UIScale.pt(11)))
                .lineLimit(1)
                .modifier(FilterChip(dark: dark, active: isCustomRangeActive))
        }
        .buttonStyle(.edith(.borderless))
        .fixedSize()
        .popover(isPresented: $customRangeOpen, arrowEdge: .bottom) {
            DashboardDateRangePicker(
                from: customFrom,
                to: customTo,
                bounds: model.dataRange ?? Date()...Date(),
                onApply: { from, to in
                    customFrom = from
                    customTo = to
                    model.range = .custom(model.ymd(from), model.ymd(to))
                    customRangeOpen = false
                },
                onCancel: { customRangeOpen = false }
            )
        }
    }

    private var customRangeLabel: String {
        guard isCustomRangeActive else { return "Custom range" }
        return
            "\(Self.shortDate.string(from: customFrom)) – \(Self.shortDate.string(from: customTo))"
    }

    private var isCustomRangeActive: Bool {
        if case .custom = model.range { return true }
        return false
    }

    private var currentMonthOption: String? {
        guard let upperBound = model.dataRange?.upperBound else { return model.monthOptions.first }
        return Self.monthKey.string(from: upperBound)
    }

    private var previousMonthOption: String? {
        guard let upperBound = model.dataRange?.upperBound,
            let date = Calendar.current.date(byAdding: .month, value: -1, to: upperBound)
        else { return model.monthOptions.dropFirst().first }
        let key = Self.monthKey.string(from: date)
        return model.monthOptions.contains(key) ? key : nil
    }

    private func monthDisplayName(_ month: String) -> String {
        guard let date = DateFormatter.monthParser.date(from: month) else { return month }
        return Self.monthName.string(from: date)
    }

    private func syncCustomDates() {
        guard model.loaded else { return }
        if case let .custom(from, to) = model.range,
            let f = DashboardModel.ymd.date(from: from),
            let t = DashboardModel.ymd.date(from: to)
        {
            customFrom = f
            customTo = t
        } else if let b = model.dataRange {
            customFrom = b.lowerBound
            customTo = b.upperBound
        }
    }

    private func rangeButton(_ title: String, _ r: DashRange) -> some View {
        let active = isActive(r)
        return Button {
            model.range = r
        } label: {
            Text(title)
                .font(DashSkin.mono(11, weight: active ? .semibold : .regular))
                .padding(.horizontal, UIScale.pt(11))
                .padding(.vertical, UIScale.pt(5))
                .widgetBar(
                    cornerRadius: 8,
                    fill: active ? AnyShapeStyle(acc) : AnyShapeStyle(DashSkin.paper2(dark)),
                    stroke: active ? Color.clear : DashSkin.lineStrong(dark)
                )
                .foregroundStyle(
                    active ? AnyShapeStyle(.white) : AnyShapeStyle(DashSkin.ink(dark)))
        }
        .buttonStyle(.edith(.borderless))
    }

    private func isActive(_ r: DashRange) -> Bool {
        switch (model.range, r) {
        case (.today, .today), (.yesterday, .yesterday), (.thisWeek, .thisWeek),
            (.lastWeek, .lastWeek), (.all, .all):
            return true
        case (.month(let selected), .month(let target)):
            return selected == target
        default: return false
        }
    }

    private var projectMenu: some View {
        Button {
            folderPickerOpen = true
        } label: {
            Label(folderScopeLabel, systemImage: "folder")
                .font(.system(size: UIScale.pt(11)))
                .lineLimit(1)
                .modifier(FilterChip(dark: dark))
        }
        .buttonStyle(.edith(.borderless)).fixedSize()
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
            Label(sourceSummary, systemImage: "square.stack.3d.up")
                .font(.system(size: UIScale.pt(11)))
                .modifier(FilterChip(dark: dark))
        }
        .buttonStyle(.edith(.borderless)).fixedSize()
        .popover(isPresented: $sourcePickerOpen, arrowEdge: .bottom) {
            FilterMultiSelect(
                options: model.allSources.map { FilterSelectOption(id: $0.id, label: $0.label) },
                selection: $model.selectedSources, dark: dark
            ) { sourcePickerOpen = false }
        }
    }

    private var sourceSummary: String {
        if model.selectedSources.count == model.allSources.count { return "All sources" }
        if model.selectedSources.count == 1, let id = model.selectedSources.first {
            return model.sourceLabel(id)
        }
        return "\(model.selectedSources.count) sources"
    }

    private var machineMenu: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let stale = selectedStaleMachines(now: timeline.date)
            Button {
                machinePickerOpen = true
            } label: {
                Label(
                    machineSummary(now: timeline.date),
                    systemImage: stale.isEmpty ? "server.rack" : "exclamationmark.triangle.fill"
                )
                .font(.system(size: UIScale.pt(11)))
                .modifier(FilterChip(dark: dark))
            }
            .buttonStyle(.edith(.borderless)).fixedSize()
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
            return "\(item.group.name) stale \(item.freshness.ageLabel)"
        }
        if stale.count > 1 { return "\(stale.count) stale machines" }
        let shown = groups.filter { model.machineIsShown($0) || model.machineIsPartlyShown($0) }
        if shown.count == groups.count { return "All machines" }
        if shown.count == 1, let only = shown.first { return only.name }
        return "\(shown.count) of \(groups.count) machines"
    }

    private func selectedStaleMachines(now: Date) -> [(
        group: MachineGroup, freshness: MachineUsageFreshness
    )] {
        model.machineGroups.compactMap { group in
            guard model.machineIsShown(group) || model.machineIsPartlyShown(group),
                let freshness = model.machineFreshness(group, now: now), freshness.isStale
            else { return nil }
            return (group, freshness)
        }
    }

    private var modelMenu: some View {
        Button {
            modelPickerOpen = true
        } label: {
            Label("\(model.selectedModels.count) models", systemImage: "cpu")
                .font(.system(size: UIScale.pt(11)))
                .modifier(FilterChip(dark: dark))
        }
        .buttonStyle(.edith(.borderless)).fixedSize()
        .popover(isPresented: $modelPickerOpen, arrowEdge: .bottom) {
            FilterMultiSelect(
                options: model.allModels.map {
                    FilterSelectOption(id: $0, label: DashFmt.shortModel($0))
                },
                selection: $model.selectedModels, dark: dark
            ) { modelPickerOpen = false }
        }
    }

    private var logView: some View {
        TerminalLogView(log: refresh.log, theme: appTheme, height: UIScale.pt(150))
    }

    private func charts(compact: Bool) -> some View {
        LazyVStack(spacing: UIScale.pt(16)) {
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
                VStack(spacing: UIScale.pt(16)) {
                    dowCard
                    shareByModelCard
                }
            } else {
                HStack(alignment: .top, spacing: UIScale.pt(16)) {
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
                                .font(.system(size: UIScale.pt(11)))
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
                            .font(.system(size: UIScale.pt(11)))
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
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .presenterBlur(blurMoney)
                    }
                    modelsTable
                }
            }
        }
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
            .font(DashSkin.mono(10, weight: .semibold)).foregroundStyle(DashSkin.inkFaint(dark))
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
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(DashSkin.ink(dark))
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                Text(DashFmt.usd(m.cost)).font(DashSkin.mono(11)).frame(
                    width: UIScale.pt(70), alignment: .trailing
                ).presenterBlur(blurMoney)
                if !compactLayout {
                    Text(DashFmt.pct(m.share)).font(DashSkin.mono(11)).frame(
                        width: UIScale.pt(60), alignment: .trailing
                    ).foregroundStyle(DashSkin.inkSoft(dark))
                }
                Text(DashFmt.tokens(m.tokens)).font(DashSkin.mono(11)).frame(
                    width: UIScale.pt(70), alignment: .trailing
                ).presenterBlur(blurUsage)
                if !compactLayout {
                    Text("\(m.days)").font(DashSkin.mono(11)).frame(
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
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: UIScale.pt(7)))
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

private struct FilterChip: ViewModifier {
    let dark: Bool
    var active = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(5))
            .widgetBar(
                cornerRadius: 8,
                fill: active
                    ? AnyShapeStyle(DashSkin.accent(dark).opacity(0.13))
                    : AnyShapeStyle(DashSkin.paper2(dark)),
                stroke: active ? DashSkin.accent(dark).opacity(0.55) : DashSkin.lineStrong(dark))
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
        let weeks = scale.weeks(days: days)
        ActivityCalendarGrid(weeks: weeks, dark: dark) { day in
            if let detail = model.heatDetail[day.id] {
                HeatCard(
                    detail: detail, model: model, dark: dark, blur: blur, blurTokens: blurTokens)
            } else {
                Text("No usage on this day.")
                    .font(.system(size: UIScale.pt(12)))
                    .padding(UIScale.pt(12))
            }
        }
    }
}
