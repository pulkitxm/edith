import Charts
import EdithKit
import SwiftUI

struct DashboardView: View {
    @StateObject private var refresh = DashboardRefreshBridge()
    @ObservedObject private var model = DashboardModel.shared
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("presenterBlurMoney", store: SharedDefaults.store) private var presenterBlurMoney =
        true
    @Environment(\.colorScheme) private var scheme
    @State private var showLog = false
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private var appTheme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var acc: Color { DashSkin.accent(dark) }
    private var gold: Color { DashSkin.gold }
    private var blurMoney: Bool { presenterState.active && presenterBlurMoney }

    var body: some View {
        VStack(spacing: 0) {
            if model.loaded {
                controlsBar
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    masthead
                        .padding(.horizontal, 24).padding(.top, 18)
                    if showLog {
                        logView.padding(.horizontal, 24)
                    }
                    if model.loaded {
                        kpiGrid.padding(.horizontal, 24)
                        LazyVStack(spacing: 16) {
                            SkinCard(title: "Activity", dark: dark) {
                                ActivityHeatmap(
                                    days: model.calendarDays, cuts: model.chartData.heatCuts,
                                    model: model, dark: dark, blur: blurMoney)
                            }
                            LimitsCardView(theme: acc, dark: dark)
                            charts
                        }
                        .padding(.horizontal, 24).padding(.bottom, 28)
                    } else if !model.loadAttempted {
                        ProgressView("Loading usage data…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ContentUnavailableView(
                            "No usage data yet", systemImage: "chart.bar",
                            description: Text("Hit reload to run the bundled collector.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(background)
        .navigationTitle("Dashboard")
        .task {
            await model.load()
        }
        .onChange(of: model.loaded) { _, loaded in
            if loaded, let b = model.dataRange {
                customFrom = b.lowerBound
                customTo = b.upperBound
            }
        }
        .onChange(of: refresh.updating) { _, updating in
            if !updating {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                HStack(spacing: 0) {
                    Text("The cost of ").foregroundStyle(DashSkin.ink(dark))
                    Text("thinking").italic().foregroundStyle(DashSkin.accentDeep(dark))
                    Text(".").foregroundStyle(DashSkin.ink(dark))
                }
                .font(DashSkin.serif(40))
                Spacer()
                mastheadButtons
            }
            WrapHStack(spacing: 6, lineSpacing: 2) {
                ForEach(metaSegments) { seg in
                    Text(seg.text)
                        .presenterBlur(seg.sensitive && blurMoney)
                }
            }
            .font(.system(size: 12.5)).foregroundStyle(DashSkin.inkSoft(dark))
        }
    }

    private var mastheadButtons: some View {
        HStack(spacing: 6) {
            Button {
                refresh.requestRefresh()
            } label: {
                Group {
                    if refresh.updating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(refresh.updating)
            .help("Refresh usage data")
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() }
            } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(showLog ? appTheme : DashSkin.inkFaint(dark))
            }
            .buttonStyle(HoverButtonStyle())
            .help("Show collector log")
        }
    }

    private struct MetaSegment: Identifiable {
        let id: Int
        let text: String
        let sensitive: Bool
    }

    private var metaSegments: [MetaSegment] {
        guard model.loaded else { return [MetaSegment(id: 0, text: "Loading…", sensitive: false)] }
        let m = model.meta
        let parts: [(String, Bool)] = [
            ("Updated \(m.updated)", false),
            (m.totalCost, true),
            ("\(m.activeDays) active days", false),
            ("\(m.totalTokens) tokens", true),
            ("\(m.modelCount) models", false),
            (m.sourceLabels, false),
        ]
        return parts.enumerated().map { index, part in
            MetaSegment(
                id: index, text: index == 0 ? part.0 : "·  \(part.0)", sensitive: part.1)
        }
    }

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
            ForEach(model.kpis) { kpi in
                HStack(spacing: 0) {
                    Rectangle().fill(kpi.hot ? acc : Color.clear).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kpi.label.uppercased())
                            .font(DashSkin.mono(10)).tracking(1.4)
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Text(kpi.value)
                            .font(DashSkin.serif(26))
                            .foregroundStyle(DashSkin.ink(dark))
                            .presenterBlur(kpi.sensitiveValue && blurMoney)
                        Text(kpi.sub)
                            .font(.system(size: 11.5)).foregroundStyle(DashSkin.inkSoft(dark))
                            .presenterBlur(blurMoney)
                    }
                    .padding(14)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DashSkin.paper2(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 14).strokeBorder(
                        DashSkin.line(dark), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(dark ? 0.3 : 0.05), radius: 8, y: 4)
            }
        }
    }

    private var controlsBar: some View {
        WrapHStack(spacing: 8, lineSpacing: 8) {
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
                    Label("Cycle", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton).pointerCursor().fixedSize()
            }
            if !model.monthOptions.isEmpty {
                Menu {
                    ForEach(model.monthOptions, id: \.self) { m in
                        Button(m) { model.range = .month(m) }
                    }
                } label: {
                    Label("Month", systemImage: "calendar.badge.clock")
                }
                .menuStyle(.borderlessButton).pointerCursor().fixedSize()
            }
            Stepper("Billing day \(model.billingDay)", value: $model.billingDay, in: 1...31)
                .pointerCursor().font(.system(size: 11)).fixedSize()
            customRange
            sourceMenu
            modelMenu
            Button("Reset") { model.reset() }
                .buttonStyle(.plain).pointerCursor().font(DashSkin.mono(11))
                .foregroundStyle(acc)
                .padding(.vertical, 5)
        }
        .foregroundStyle(DashSkin.inkSoft(dark))
        .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper(dark))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
        }
    }

    private var customRange: some View {
        HStack(spacing: 4) {
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
            Text("→").font(.system(size: 10)).foregroundStyle(DashSkin.inkFaint(dark))
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

    private func rangeButton(_ title: String, _ r: DashRange) -> some View {
        let active = isActive(r)
        return Button(title) { model.range = r }
            .buttonStyle(.plain)
            .pointerCursor()
            .font(DashSkin.mono(11, weight: active ? .semibold : .regular))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                active ? AnyShapeStyle(acc) : AnyShapeStyle(DashSkin.paper2(dark)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(active ? Color.clear : DashSkin.lineStrong(dark), lineWidth: 1)
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

    private var sourceMenu: some View {
        Menu {
            ForEach(model.allSources) { s in
                Toggle(
                    s.label,
                    isOn: Binding(
                        get: { model.selectedSources.contains(s.id) },
                        set: { on in
                            if on {
                                model.selectedSources.insert(s.id)
                            } else if model.selectedSources.count > 1 {
                                model.selectedSources.remove(s.id)
                            }
                        }))
            }
        } label: {
            Label(sourceSummary, systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton).pointerCursor().fixedSize()
    }

    private var sourceSummary: String {
        if model.selectedSources.count == model.allSources.count { return "All sources" }
        if model.selectedSources.count == 1, let id = model.selectedSources.first {
            return model.sourceLabel(id)
        }
        return "\(model.selectedSources.count) sources"
    }

    private var modelMenu: some View {
        Menu {
            ForEach(model.allModels, id: \.self) { m in
                Toggle(
                    DashFmt.shortModel(m),
                    isOn: Binding(
                        get: { model.selectedModels.contains(m) },
                        set: { on in
                            if on {
                                model.selectedModels.insert(m)
                            } else if model.selectedModels.count > 1 {
                                model.selectedModels.remove(m)
                            }
                        }))
            }
        } label: {
            Label("\(model.selectedModels.count) models", systemImage: "cpu")
        }
        .menuStyle(.borderlessButton).pointerCursor().fixedSize()
    }

    private var logView: some View {
        TerminalLogView(log: refresh.log, theme: appTheme, height: 150)
    }

    @ViewBuilder private var charts: some View {
        SkinCard(title: "Daily usage", dark: dark) {
            ComboChart(
                points: model.chartData.daily, barColor: acc, lineColor: gold, dark: dark,
                scroll: true, blur: blurMoney)
        }
        SkinCard(title: "Token mix by day", dark: dark) {
            StackedChart(
                bars: model.chartData.tokenMix, costLine: model.chartData.daily,
                domain: tokenMixDomain, range: tokenMixRange, dark: dark, blur: blurMoney)
        }
        SkinCard(title: "Model usage over time", dark: dark) {
            StackedChart(
                bars: model.chartData.modelTime, costLine: model.chartData.daily,
                domain: modelDomain, range: modelRange, dark: dark, blur: blurMoney)
        }
        if model.allSources.count > 1 {
            SkinCard(title: "Usage by source over time", dark: dark) {
                StackedChart(
                    bars: model.chartData.source, costLine: model.chartData.daily,
                    domain: sourceDomain, range: sourceRange, dark: dark, blur: blurMoney)
            }
        }
        HStack(alignment: .top, spacing: 16) {
            SkinCard(title: "By day of week", dark: dark) {
                ComboChart(
                    points: model.chartData.dow, barColor: acc, lineColor: gold, dark: dark,
                    height: 200, blur: blurMoney)
            }
            SkinCard(title: "Share by model", dark: dark) {
                DonutChart(slices: donutSlices, blur: blurMoney)
            }
        }
        if !model.projects.isEmpty {
            SkinCard(title: "By project", dark: dark) {
                VStack(alignment: .leading, spacing: 12) {
                    ComboChart(
                        points: model.chartData.project, barColor: acc, lineColor: gold,
                        dark: dark, height: 280, blur: blurMoney)
                    ProjectDrilldownView(model: model, dark: dark, blur: blurMoney)
                }
            }
        }
        SkinCard(title: "Hourly - all time", dark: dark) {
            ComboChart(
                points: model.chartData.hourly, barColor: acc, lineColor: gold, dark: dark,
                height: 200, blur: blurMoney)
        }
        SkinCard(title: "Models", dark: dark) { modelsTable }
    }

    private var modelsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                tableHeader("Model", .model, width: nil)
                tableHeader("Cost", .cost, width: 70)
                tableHeader("Share", .share, width: 60)
                tableHeader("Tokens", .tokens, width: 70)
                tableHeader("Days", .days, width: 44)
            }
            .font(DashSkin.mono(10, weight: .semibold)).foregroundStyle(DashSkin.inkFaint(dark))
            .padding(.vertical, 4)
            Rectangle().fill(DashSkin.line(dark)).frame(height: 1)
            ForEach(model.modelTotals) { m in
                HStack(spacing: 8) {
                    Circle().fill(model.modelColor(m.model, dark: dark)).frame(width: 8, height: 8)
                    Text(DashFmt.shortModel(m.model))
                        .font(.system(size: 11)).foregroundStyle(DashSkin.ink(dark))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(DashFmt.usd(m.cost)).font(DashSkin.mono(11)).frame(
                        width: 70, alignment: .trailing
                    ).presenterBlur(blurMoney)
                    Text(DashFmt.pct(m.share)).font(DashSkin.mono(11)).frame(
                        width: 60, alignment: .trailing
                    ).foregroundStyle(DashSkin.inkSoft(dark))
                    Text(DashFmt.tokens(m.tokens)).font(DashSkin.mono(11)).frame(
                        width: 70, alignment: .trailing
                    ).presenterBlur(blurMoney)
                    Text("\(m.days)").font(DashSkin.mono(11)).frame(width: 44, alignment: .trailing)
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.vertical, 5)
                Rectangle().fill(DashSkin.line(dark).opacity(0.5)).frame(height: 1)
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
            HStack(spacing: 2) {
                Text(title)
                if model.sortColumn == col {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
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
        model.modelTotals.filter { $0.tokens > 0 }.map {
            DonutSlice(
                id: $0.model, label: DashFmt.shortModel($0.model), value: $0.tokens,
                color: model.modelColor($0.model, dark: dark))
        }
    }
}

struct ActivityHeatmap: View {
    let days: [DayPoint]
    let cuts: [Double]
    let model: DashboardModel
    let dark: Bool
    var blur = false
    @State private var hoveredDay: String?

    var body: some View {
        let weeks = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        return HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 3) {
                ForEach(Array(["M", "", "W", "", "F", "", "S"].enumerated()), id: \.offset) {
                    _, label in
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: 12, height: 14)
                }
            }
            .padding(.top, 15)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                        VStack(spacing: 3) {
                            Text(monthLabel(for: weeks, at: index))
                                .font(.system(size: 9))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .frame(height: 12)
                            ForEach(week) { day in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(cellColor(day.cost, cuts: cuts))
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(
                                                DashSkin.ink(dark).opacity(
                                                    hoveredDay == day.id ? 0.5 : 0),
                                                lineWidth: 1)
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
                                                blur: blur)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .defaultScrollAnchor(weeks.count > 18 ? .trailing : .leading)
        }
        .frame(height: 137)
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
        if cost <= cuts[0] { return DashPalette.color("#f6d9bf") }
        if cost <= cuts[1] { return DashPalette.color("#f0b384") }
        if cost <= cuts[2] { return DashPalette.color("#e2884f") }
        return DashPalette.color("#c75e36")
    }
}
