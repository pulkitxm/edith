import Charts
import EdithKit
import SwiftUI

struct DashboardView: View {
    @State private var refresh = DashboardRefreshBridge()
    @State private var model = DashboardModel.shared
    private var presenterState = PresenterState.shared
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
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private var appTheme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var acc: Color { DashSkin.accent(dark) }
    private var gold: Color { DashSkin.gold }
    private var blurMoney: Bool { presenterState.active && presenterBlurMoney }
    private var blurUsage: Bool { presenterState.active && presenterBlurUsage }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < UIScale.pt(640)
            VStack(spacing: UIScale.pt(0)) {
                masthead
                if model.loaded {
                    controlsBar
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                        if showLog {
                            logView.pageGutter(compact)
                        }
                        if model.loaded {
                            kpiGrid.pageGutter(compact)
                            LazyVStack(spacing: UIScale.pt(16)) {
                                activityRow(compact: compact)
                                LimitsCardView(theme: acc, dark: dark)
                                BudgetCardView(theme: acc, dark: dark)
                                charts(compact: compact)
                            }
                            .pageContent(compact)
                            .animation(
                                Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                                value: model.revision)
                        } else if !model.loadAttempted {
                            ProgressView("Loading usage data…")
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: UIScale.pt(240))
                        } else {
                            ContentUnavailableView(
                                "No usage data yet", systemImage: "chart.bar",
                                description: Text("Hit reload to run the bundled collector.")
                            )
                            .frame(maxWidth: .infinity, minHeight: UIScale.pt(240))
                        }
                    }
                    .padding(.top, UIScale.pt(16))
                    .frame(maxWidth: .infinity)
                }
            }
            .background(background)
            .environment(\.compactLayout, compact)
        }
        .navigationTitle("Agent Usage")
        .task {
            guard automaticActionsEnabled else { return }
            await model.load()
            syncCustomDates()
        }
        .onChange(of: model.loaded) { _, loaded in
            if automaticActionsEnabled, loaded { syncCustomDates() }
        }
        .onChange(of: refresh.updating) { _, updating in
            if automaticActionsEnabled, !updating {
                Task { await model.load() }
            }
        }
    }

    private var background: some View {
        DashSkin.paper(dark)
            .overlay(alignment: .topTrailing) {
                RadialGradient(
                    colors: [acc.opacity(0.08), .clear], center: .topTrailing,
                    startRadius: 0, endRadius: 620
                )
                .ignoresSafeArea(edges: .vertical)
            }
            .overlay(alignment: .bottomLeading) {
                RadialGradient(
                    colors: [DashPalette.slate(dark).opacity(0.06), .clear], center: .bottomLeading,
                    startRadius: 0, endRadius: 520
                )
                .ignoresSafeArea(edges: .vertical)
            }
            .ignoresSafeArea(edges: .vertical)
    }

    private var masthead: some View {
        PageHeader {
            (Text("The cost of ").foregroundStyle(DashSkin.ink(dark))
                + Text("Thinking").italic().foregroundStyle(DashSkin.accentDeep(dark))
                + Text(".").foregroundStyle(DashSkin.ink(dark)))
        } trailing: {
            mastheadButtons
        } accessory: {
            WrapHStack(spacing: UIScale.pt(6), lineSpacing: 2) {
                ForEach(metaSegments) { seg in
                    Text(seg.text)
                        .presenterBlur((seg.sensitive && blurMoney) || (seg.usage && blurUsage))
                }
            }
            .font(.system(size: UIScale.pt(12.5))).foregroundStyle(DashSkin.inkSoft(dark))
        }
    }

    private var mastheadButtons: some View {
        HStack(spacing: UIScale.pt(6)) {
            MastheadButton(
                action: refresh.requestRefresh,
                systemImage: "arrow.clockwise",
                helperText: "Refresh usage data",
                isLoading: refresh.updating
            )
            MastheadButton(
                action: { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } },
                systemImage: "terminal",
                helperText: "Show collector log",
                tint: showLog ? appTheme : DashSkin.inkFaint(dark)
            )
        }
    }

    private struct MastheadButton: View {
        let action: () -> Void
        let systemImage: String
        let helperText: String
        var isLoading = false
        var tint: Color?

        var body: some View {
            Button(action: action) {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if let tint {
                        Image(systemName: systemImage).foregroundStyle(tint)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .frame(width: UIScale.pt(18), height: UIScale.pt(18))
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(isLoading)
            .help(helperText)
        }
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
            (m.totalCost, true, false),
            ("\(m.activeDays) active days", false, false),
            ("\(m.totalTokens) tokens", false, true),
            ("\(m.modelCount) models", false, false),
            (m.sourceLabels, false, false),
        ]
        return parts.enumerated().map { index, part in
            MetaSegment(
                id: index, text: index == 0 ? part.0 : "·  \(part.0)", sensitive: part.1,
                usage: part.2)
        }
    }

    private var kpiColumns: [GridItem] {
        [GridItem(.adaptive(minimum: UIScale.pt(158)), spacing: UIScale.pt(12))]
    }

    private var kpiGrid: some View {
        LazyVGrid(columns: kpiColumns, spacing: UIScale.pt(12)) {
            ForEach(model.kpis) { kpi in
                HStack(spacing: UIScale.pt(0)) {
                    Rectangle().fill(kpi.hot ? acc : Color.clear).frame(width: UIScale.pt(3))
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(kpi.label.uppercased())
                            .font(DashSkin.mono(10)).tracking(UIScale.pt(1.4))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(kpi.value)
                            .font(DashSkin.serif(26))
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
                .background(DashSkin.paper2(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(14)).strokeBorder(
                        DashSkin.line(dark), lineWidth: UIScale.pt(1))
                )
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(14)))
                .background {
                    RoundedRectangle(cornerRadius: UIScale.pt(14))
                        .fill(DashSkin.paper2(dark))
                        .shadow(
                            color: .black.opacity(dark ? 0.3 : 0.05), radius: UIScale.pt(8), y: 4)
                }
            }
        }
    }

    @ViewBuilder private func activityRow(compact: Bool) -> some View {
        if compact {
            VStack(spacing: UIScale.pt(16)) {
                SkinCard(title: "Activity", dark: dark) { activityHeatmap }
                RateLimitsDialsView(dark: dark)
            }
        } else {
            HStack(alignment: .top, spacing: UIScale.pt(16)) {
                SkinCard(title: "Activity", dark: dark, fill: true) { activityHeatmap }
                RateLimitsDialsView(dark: dark, fill: true).frame(width: UIScale.pt(340))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activityHeatmap: some View {
        ActivityHeatmap(
            days: model.calendarDays, cuts: model.chartData.heatCuts,
            model: model, dark: dark, blur: blurMoney, blurTokens: blurUsage
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlsBar: some View {
        VStack(spacing: 10) {
            WrapHStack(spacing: UIScale.pt(8), lineSpacing: 8) {
                rangeButton("Today", .today)
                rangeButton("Yesterday", .yesterday)
                rangeButton("Week", .thisWeek)
                rangeButton("Last week", .lastWeek)
                rangeButton("Cycle", .cycle(nil))
                rangeButton("All", .all)
                if !model.cycleOptions.isEmpty {
                    Menu {
                        ForEach(model.cycleOptions) { c in
                            Button(c.label) { model.range = .cycle(c.id) }
                        }
                    } label: {
                        Label("Cycle", systemImage: "calendar").font(.system(size: UIScale.pt(11)))
                    }
                    .menuStyle(.borderlessButton).pointerCursor().fixedSize()
                    .modifier(FilterChip(dark: dark))
                }
                if !model.monthOptions.isEmpty {
                    Menu {
                        ForEach(model.monthOptions, id: \.self) { m in
                            Button(m) { model.range = .month(m) }
                        }
                    } label: {
                        Label("Month", systemImage: "calendar.badge.clock")
                            .font(.system(size: UIScale.pt(11)))
                    }
                    .menuStyle(.borderlessButton).pointerCursor().fixedSize()
                    .modifier(FilterChip(dark: dark))
                }
                if !model.machineGroups.isEmpty { machineMenu }
                Button("Reset") { model.reset() }
                    .buttonStyle(.plain).pointerCursor().font(DashSkin.mono(11))
                    .foregroundStyle(acc)
                    .padding(.vertical, UIScale.pt(5))
            }
            WrapHStack(spacing: UIScale.pt(8), lineSpacing: 8) {
                modelMenu
                projectMenu
                sourceMenu
                billingDayControl
                customRange
            }
        }
        .foregroundStyle(DashSkin.inkSoft(dark))
        .pageGutter(compactLayout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }

    private var billingDayControl: some View {
        HStack(spacing: UIScale.pt(6)) {
            Text("Billing day \(model.billingDay)")
                .font(.system(size: UIScale.pt(11)))
                .monospacedDigit()
            HStack(spacing: UIScale.pt(2)) {
                billingDayStep("minus", enabled: model.billingDay > 1) { model.billingDay -= 1 }
                billingDayStep("plus", enabled: model.billingDay < 31) { model.billingDay += 1 }
            }
        }
        .pointerCursor().fixedSize()
        .modifier(FilterChip(dark: dark))
    }

    private func billingDayStep(_ systemImage: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: UIScale.pt(9), weight: .semibold))
                .frame(width: UIScale.pt(14), height: UIScale.pt(14))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
    }

    private var customRange: some View {
        HStack(spacing: UIScale.pt(4)) {
            DatePicker(
                "",
                selection: Binding(
                    get: { customFrom },
                    set: {
                        customFrom = $0
                        model.range = .custom(model.ymd($0), model.ymd(customTo))
                    }),
                in: (model.dataRange ?? Date()...Date()), displayedComponents: .date
            )
            .labelsHidden().datePickerStyle(.field).pointerCursor().controlSize(.small)
            Text("→").font(.system(size: UIScale.pt(10))).foregroundStyle(DashSkin.inkFaint(dark))
            DatePicker(
                "",
                selection: Binding(
                    get: { customTo },
                    set: {
                        customTo = $0
                        model.range = .custom(model.ymd(customFrom), model.ymd($0))
                    }),
                in: (model.dataRange ?? Date()...Date()), displayedComponents: .date
            )
            .labelsHidden().datePickerStyle(.field).pointerCursor().controlSize(.small)
        }
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
        return Button(title) { model.range = r }
            .buttonStyle(.plain)
            .pointerCursor()
            .font(DashSkin.mono(11, weight: active ? .semibold : .regular))
            .padding(.horizontal, UIScale.pt(11)).padding(.vertical, UIScale.pt(5))
            .background(
                active ? AnyShapeStyle(acc) : AnyShapeStyle(DashSkin.paper2(dark)),
                in: RoundedRectangle(cornerRadius: UIScale.pt(8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(
                        active ? Color.clear : DashSkin.lineStrong(dark), lineWidth: UIScale.pt(1))
            )
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(DashSkin.ink(dark)))
    }

    private func isActive(_ r: DashRange) -> Bool {
        switch (model.range, r) {
        case (.today, .today), (.yesterday, .yesterday), (.thisWeek, .thisWeek),
            (.lastWeek, .lastWeek), (.all, .all), (.cycle, .cycle):
            return true
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
        }
        .buttonStyle(.plain).pointerCursor().fixedSize()
        .modifier(FilterChip(dark: dark))
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
        }
        .buttonStyle(.plain).pointerCursor().fixedSize()
        .modifier(FilterChip(dark: dark))
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
            }
            .buttonStyle(.plain).pointerCursor().fixedSize()
            .modifier(FilterChip(dark: dark))
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
        }
        .buttonStyle(.plain).pointerCursor().fixedSize()
        .modifier(FilterChip(dark: dark))
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

    @ViewBuilder private func charts(compact: Bool) -> some View {
        SkinCard(title: "Daily usage", dark: dark) {
            ComboChart(
                points: model.chartData.daily, barColor: acc, lineColor: gold, dark: dark,
                scroll: true, blur: blurMoney, blurTokens: blurUsage)
        }
        SkinCard(title: "Token mix by day", dark: dark) {
            StackedChart(
                bars: model.chartData.tokenMix, costLine: model.chartData.daily,
                domain: tokenMixDomain, range: tokenMixRange, dark: dark, blur: blurMoney,
                blurTokens: blurUsage)
        }
        SkinCard(title: "Model usage over time", dark: dark) {
            StackedChart(
                bars: model.chartData.modelTime, costLine: model.chartData.daily,
                domain: modelDomain, range: modelRange, dark: dark, blur: blurMoney,
                blurTokens: blurUsage)
        }
        if model.allSources.count > 1 {
            SkinCard(title: "Usage by source over time", dark: dark) {
                StackedChart(
                    bars: model.chartData.source, costLine: model.chartData.daily,
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
            SkinCard(title: "By project", dark: dark) {
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
        SkinCard(title: "Hourly usage", dark: dark) {
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
        SkinCard(title: "Models", dark: dark) {
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
        SkinCard(title: "By day of week", dark: dark) {
            ComboChart(
                points: model.chartData.dow, barColor: acc, lineColor: gold, dark: dark,
                height: UIScale.pt(200), blur: blurMoney, blurTokens: blurUsage)
        }
    }

    private var shareByModelCard: some View {
        SkinCard(title: "Share by model", dark: dark) {
            DonutChart(slices: donutSlices, blurTokens: blurUsage)
        }
    }

    private var modelsTable: some View {
        VStack(spacing: UIScale.pt(0)) {
            HStack(spacing: UIScale.pt(8)) {
                tableHeader("Model", .model, width: nil)
                tableHeader("Cost", .cost, width: UIScale.pt(70))
                tableHeader("Share", .share, width: UIScale.pt(60))
                tableHeader("Tokens", .tokens, width: UIScale.pt(70))
                tableHeader("Days", .days, width: UIScale.pt(44))
            }
            .font(DashSkin.mono(10, weight: .semibold)).foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.vertical, UIScale.pt(4))
            Rectangle().fill(DashSkin.line(dark)).frame(height: UIScale.pt(1))
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
                    Text(DashFmt.pct(m.share)).font(DashSkin.mono(11)).frame(
                        width: UIScale.pt(60), alignment: .trailing
                    ).foregroundStyle(DashSkin.inkSoft(dark))
                    Text(DashFmt.tokens(m.tokens)).font(DashSkin.mono(11)).frame(
                        width: UIScale.pt(70), alignment: .trailing
                    ).presenterBlur(blurUsage)
                    Text("\(m.days)").font(DashSkin.mono(11)).frame(
                        width: UIScale.pt(44), alignment: .trailing
                    )
                    .foregroundStyle(DashSkin.inkSoft(dark))
                }
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.vertical, UIScale.pt(5))
                Rectangle().fill(DashSkin.line(dark).opacity(0.5)).frame(height: UIScale.pt(1))
            }
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
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var tokenMixDomain: [String] { ["input", "output", "cache write", "cache read"] }
    private var tokenMixRange: [Color] {
        [
            DashPalette.inputColor(dark), DashPalette.outputColor(dark),
            DashPalette.cacheCreateColor, DashPalette.cacheReadColor,
        ]
    }
    private var modelDomain: [String] { model.allModels.map(DashFmt.shortModel) }
    private var modelRange: [Color] { model.allModels.map { model.modelColor($0, dark: dark) } }
    private var sourceDomain: [String] { model.allSources.map(\.label) }
    private var sourceRange: [Color] {
        model.allSources.map { model.sourceColor($0.id, dark: dark) }
    }
    private var donutSlices: [DonutSlice] {
        model.tokenBearingModelTotals.map {
            DonutSlice(
                id: $0.model, label: model.modelLabel($0.model), value: $0.tokens,
                color: model.modelColor($0.model, dark: dark))
        }
    }
}

private struct FilterChip: ViewModifier {
    let dark: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(5))
            .background(
                DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(DashSkin.lineStrong(dark), lineWidth: UIScale.pt(1))
            )
    }
}

struct ActivityHeatmap: View {
    let days: [DayPoint]
    let cuts: [Double]
    let model: DashboardModel
    let dark: Bool
    var blur = false
    var blurTokens = false
    @State private var hoveredDay: String?

    var body: some View {
        let weeks = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        return HStack(alignment: .top, spacing: UIScale.pt(4)) {
            VStack(spacing: UIScale.pt(3)) {
                ForEach(Array(["M", "", "W", "", "F", "", "S"].enumerated()), id: \.offset) {
                    _, label in
                    Text(label)
                        .font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(12), height: UIScale.pt(14))
                }
            }
            .padding(.top, UIScale.pt(15))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        VStack(spacing: UIScale.pt(3)) {
                            Text(monthLabel(for: weeks, at: index))
                                .font(.system(size: UIScale.pt(9)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(height: UIScale.pt(12))
                            ForEach(week) { day in
                                RoundedRectangle(cornerRadius: UIScale.pt(3))
                                    .fill(cellColor(day.cost, cuts: cuts))
                                    .frame(width: UIScale.pt(14), height: UIScale.pt(14))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: UIScale.pt(3))
                                            .strokeBorder(
                                                DashSkin.ink(dark).opacity(
                                                    hoveredDay == day.id ? 0.5 : 0),
                                                lineWidth: UIScale.pt(1))
                                    )
                                    .onHover { inside in
                                        if inside {
                                            hoveredDay =
                                                model.heatDetail[day.id] != nil ? day.id : nil
                                        } else if hoveredDay == day.id {
                                            hoveredDay = nil
                                        }
                                    }
                                    .popover(
                                        isPresented: Binding(
                                            get: { hoveredDay == day.id },
                                            set: { if !$0 { hoveredDay = nil } }),
                                        arrowEdge: .trailing
                                    ) {
                                        if let detail = model.heatDetail[day.id] {
                                            HeatCard(
                                                detail: detail, model: model, dark: dark,
                                                blur: blur, blurTokens: blurTokens)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .defaultScrollAnchor(weeks.count > 18 ? .trailing : .leading)
        }
        .frame(height: UIScale.pt(137))
    }

    private func monthLabel(for weeks: [[DayPoint]], at index: Int) -> String {
        guard let first = weeks[index].first?.date else { return "" }
        let month = Calendar.current.component(.month, from: first)
        if index > 0, let prev = weeks[index - 1].first?.date,
            Calendar.current.component(.month, from: prev) == month
        {
            return ""
        }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    private func cellColor(_ cost: Double, cuts: [Double]) -> Color {
        if cost <= 0 { return DashSkin.grid(dark) }
        if cost <= cuts[0] { return DashPalette.color("#008000") }
        if cost <= cuts[1] { return DashPalette.color("#006400") }
        if cost <= cuts[2] { return DashPalette.color("#004700") }
        return DashPalette.color("#002B00")
    }
}
