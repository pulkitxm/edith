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
    @State private var customRangeOpen = false
    @State private var showShare = false
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private var appTheme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var acc: Color { DashSkin.accent(dark) }
    private var gold: Color { DashSkin.gold }
    private var blurMoney: Bool { presenterState.active && presenterBlurMoney }
    private var blurUsage: Bool { presenterState.active && presenterBlurUsage }

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

    var body: some View {
        ZStack {
            GeometryReader { geo in
                let compact = geo.size.width < UIScale.pt(640)
                VStack(spacing: UIScale.pt(0)) {
                    masthead
                    if model.loaded {
                        controlsBar
                    } else if !model.loadAttempted {
                        DashboardControlsSkeleton(dark: dark)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                            if showLog {
                                logView.pageGutter(compact)
                            }
                            if model.loaded {
                                kpiGrid.pageGutter(compact)
                                VStack(spacing: UIScale.pt(16)) {
                                    activityRow(compact: compact)
                                    LimitsCardView(theme: acc, dark: dark)
                                    BudgetCardView(theme: acc, dark: dark)
                                    charts(compact: compact)
                                }
                                .pageContent(compact)
                            } else if !model.loadAttempted {
                                DashboardPageSkeleton(dark: dark)
                                    .pageContent(compact)
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
            if showShare {
                shareOverlay
                    .zIndex(10)
            }
        }
        .animation(Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: showShare)
        .navigationTitle("Agent Usage")
        .task(id: refresh.updating) {
            guard automaticActionsEnabled else { return }
            guard !refresh.updating else { return }
            await model.load()
            syncCustomDates()
        }
        .onAppear {
            guard automaticActionsEnabled else { return }
            model.beginObserving()
        }
        .onDisappear {
            guard automaticActionsEnabled else { return }
            model.endObserving()
        }
        .onChange(of: model.loaded) { _, loaded in
            if automaticActionsEnabled, loaded { syncCustomDates() }
        }
        .onChange(of: showLog) { _, shown in
            refresh.setLogVisible(shown)
        }
    }

    private var shareOverlay: some View {
        ZStack {
            Button(action: closeShare) {
                Color.black.opacity(dark ? 0.66 : 0.3)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.edith(.borderless))
            .transition(.opacity)
            UsageShareSheet(snapshot: shareSnapshot, onDismiss: closeShare)
                .shadow(color: .black.opacity(0.34), radius: 40, y: 18)
                .transition(
                    Motion.transition(
                        .move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion,
                        preferCrossFade: false))
        }
    }

    private func closeShare() {
        withAnimation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion)) {
            showShare = false
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
                + Text("Thinking").italic().foregroundStyle(DashSkin.accentDeep(dark)))
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
            } else {
                SkeletonGroup {
                    HStack(spacing: UIScale.pt(8)) {
                        SkeletonBlock(width: 112, height: 9)
                        SkeletonBlock(width: 64, height: 9)
                        SkeletonBlock(width: 86, height: 9)
                    }
                }
                .accessibilityLabel("Loading usage summary")
            }
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
            if model.loaded {
                OrbitingShareButton(
                    action: {
                        withAnimation(
                            Motion.animation(Motion.feedback, reduceMotion: reduceMotion)
                        ) {
                            showShare = true
                        }
                    },
                    dark: dark)
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
                        SkeletonGroup {
                            SkeletonBlock(width: 18, height: 18, corner: 9)
                        }
                    } else if let tint {
                        Image(systemName: systemImage).foregroundStyle(tint)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .frame(width: UIScale.pt(18), height: UIScale.pt(18))
            }
            .buttonStyle(.edith(.toolbar))
            .disabled(isLoading)
            .help(helperText)
        }
    }

    private struct OrbitingShareButton: View {
        let action: () -> Void
        let dark: Bool

        @State private var hovering = false
        @State private var rotation = 0.0

        private var ink: Color { DashSkin.ink(dark) }

        var body: some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(ink.opacity(hovering ? 0.11 : 0.065))
                    Circle()
                        .strokeBorder(ink.opacity(0.14), lineWidth: 1)
                    CircularShareText(color: ink.opacity(0.72))
                        .rotationEffect(.degrees(rotation))
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        .foregroundStyle(ink)
                }
                .frame(width: UIScale.pt(50), height: UIScale.pt(50))
                .scaleEffect(hovering ? 1.07 : 1)
                .animation(.easeOut(duration: 0.18), value: hovering)
            }
            .buttonStyle(.edith(.borderless))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .onHover { hovering = $0 }
            .help("Share usage cards")
            .accessibilityLabel("Share usage cards")
        }
    }

    private struct CircularShareText: View {
        let color: Color
        private let letters = Array("SHARE • SHARE • ")

        var body: some View {
            ZStack {
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    Text(String(letter))
                        .font(.system(size: UIScale.pt(5.4), weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .offset(y: UIScale.pt(-19))
                        .rotationEffect(.degrees(Double(index) * 360 / Double(letters.count)))
                }
            }
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
                .widgetBar(
                    cornerRadius: 14,
                    fill: DashSkin.paper2(dark),
                    stroke: DashSkin.line(dark),
                    shadow: .black.opacity(dark ? 0.3 : 0.05),
                    shadowRadius: 8,
                    shadowY: 4,
                    clipsContent: true
                )
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
        .pageGutter(compactLayout)
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
            SkinCard(
                title: "Models", note: "\(model.modelTotals.count) total", dark: dark
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

private struct HeatHover: Identifiable {
    let id: String
    let detail: HeatDay
}

struct ActivityHeatmap: View {
    let days: [DayPoint]
    let cuts: [Double]
    let model: DashboardModel
    let dark: Bool
    var blur = false
    var blurTokens = false
    @State private var hovered: HeatHover?

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
                LazyHStack(alignment: .top, spacing: UIScale.pt(3)) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        VStack(spacing: UIScale.pt(3)) {
                            Text(monthLabel(for: weeks, at: index))
                                .font(.system(size: UIScale.pt(9)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(height: UIScale.pt(12))
                            ForEach(week) { day in
                                HeatCellView(
                                    fill: cellColor(day.cost, cuts: cuts),
                                    stroke: DashSkin.ink(dark).opacity(
                                        hovered?.id == day.id ? 0.5 : 0)
                                )
                                .onHover { inside in
                                    if inside {
                                        if let detail = model.heatDetail[day.id] {
                                            hovered = HeatHover(id: day.id, detail: detail)
                                        } else {
                                            hovered = nil
                                        }
                                    } else if hovered?.id == day.id {
                                        hovered = nil
                                    }
                                }
                                .popover(
                                    isPresented: Binding(
                                        get: { hovered?.id == day.id },
                                        set: { shown in
                                            if !shown, hovered?.id == day.id { hovered = nil }
                                        }),
                                    arrowEdge: .trailing
                                ) {
                                    if let hovered, hovered.id == day.id {
                                        HeatCard(
                                            detail: hovered.detail, model: model, dark: dark,
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
        if cost <= cuts[0] { return DashSkin.heat(0, dark) }
        if cost <= cuts[1] { return DashSkin.heat(1, dark) }
        if cost <= cuts[2] { return DashSkin.heat(2, dark) }
        return DashSkin.heat(3, dark)
    }
}

private struct HeatCellView: View {
    let fill: Color
    let stroke: Color

    var body: some View {
        RoundedRectangle(cornerRadius: UIScale.pt(3))
            .fill(fill)
            .frame(width: UIScale.pt(14), height: UIScale.pt(14))
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(3))
                    .strokeBorder(stroke, lineWidth: UIScale.pt(1))
            )
    }
}

private struct DashboardControlsSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(10)) {
                SkeletonBlock(width: 220, height: 28, corner: 7)
                SkeletonBlock(width: 118, height: 28, corner: 7)
                Spacer()
                SkeletonBlock(width: 76, height: 28, corner: 7)
            }
            .padding(.horizontal, PageMetrics.gutter(false))
            .padding(.vertical, UIScale.pt(10))
            .background(DashSkin.paper2(dark).opacity(0.45))
        }
        .accessibilityLabel("Loading usage controls")
    }
}

private struct DashboardPageSkeleton: View {
    let dark: Bool
    @Environment(\.compactLayout) private var compact

    var body: some View {
        SkeletonGroup {
            VStack(spacing: UIScale.pt(16)) {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: UIScale.pt(compact ? 145 : 190)),
                            spacing: UIScale.pt(12))
                    ],
                    spacing: UIScale.pt(12)
                ) {
                    ForEach(0..<4, id: \.self) { index in
                        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                            HStack {
                                SkeletonBlock(width: 76, height: 8)
                                Spacer()
                                SkeletonBlock(width: 20, height: 20, corner: 6)
                            }
                            SkeletonBlock(
                                width: index.isMultiple(of: 2) ? 94 : 68,
                                height: 20)
                            SkeletonBlock(width: 104, height: 8)
                        }
                        .padding(UIScale.pt(14))
                        .background(
                            DashSkin.paper2(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
                    }
                }
                DashboardSkeletonCard(height: 150, dark: dark, rows: 3)
                HStack(spacing: UIScale.pt(12)) {
                    DashboardSkeletonCard(height: 190, dark: dark, rows: 2)
                    if !compact {
                        DashboardSkeletonCard(height: 190, dark: dark, rows: 3)
                    }
                }
                ForEach(0..<4, id: \.self) { _ in
                    DashboardSkeletonCard(height: 220, dark: dark, rows: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(240), alignment: .top)
        .accessibilityLabel("Loading usage data")
    }
}

private struct DashboardSkeletonCard: View {
    let height: CGFloat
    let dark: Bool
    let rows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                SkeletonBlock(width: 118, height: 10)
                Spacer()
                SkeletonBlock(width: 68, height: 8)
            }
            ForEach(0..<rows, id: \.self) { index in
                SkeletonBlock(
                    width: index == rows - 1 ? 176 : nil,
                    height: index == 0 && rows == 1 ? height - 54 : 9,
                    corner: index == 0 && rows == 1 ? 10 : 4)
            }
            Spacer(minLength: 0)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(height), alignment: .topLeading)
        .background(
            DashSkin.paper2(dark),
            in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }
}
