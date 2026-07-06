import Charts
import EdithKit
import SwiftUI

struct DashboardView: View {
    @StateObject private var refresh = DashboardRefreshBridge()
    @ObservedObject private var model = DashboardModel.shared
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @Environment(\.colorScheme) private var scheme
    @State private var showLog = false
    @State private var customFrom = Date()
    @State private var customTo = Date()

    private var appTheme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }
    private var acc: Color { DashSkin.accent(dark) }
    private var gold: Color { DashSkin.gold }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                masthead
                    .padding(.horizontal, 24).padding(.top, 22)
                if showLog {
                    logView.padding(.horizontal, 24)
                }
                if model.loaded {
                    kpiGrid.padding(.horizontal, 24)
                    Section {
                        VStack(spacing: 16) {
                            SkinCard(title: "Activity", dark: dark) {
                                ActivityHeatmap(
                                    days: model.calendarDays, model: model, dark: dark)
                            }
                            LimitsCardView(theme: acc, dark: dark)
                            charts
                        }
                        .padding(.horizontal, 24).padding(.bottom, 28)
                    } header: {
                        controlsBar
                    }
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
        .background(background)
        .frame(minWidth: 760, minHeight: 600)
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
            Text(metaText)
                .font(.system(size: 12.5)).foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
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

    private var metaText: String {
        guard model.loaded else { return "Loading…" }
        let m = model.meta
        return [
            "Updated \(m.updated)", m.totalCost, "\(m.activeDays) active days",
            "\(m.totalTokens) tokens", "\(m.modelCount) models", m.sourceLabels,
        ].joined(separator: "  ·  ")
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
                        Text(kpi.sub)
                            .font(.system(size: 11.5)).foregroundStyle(DashSkin.inkSoft(dark))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                rangeButton("Today", .today)
                rangeButton("Yesterday", .yesterday)
                rangeButton("Week", .thisWeek)
                rangeButton("Last week", .lastWeek)
                rangeButton("Cycle", .cycle(nil))
                rangeButton("All", .all)
                Spacer()
                Button("Reset") { model.reset() }
                    .buttonStyle(.plain).pointerCursor().font(DashSkin.mono(11))
                    .foregroundStyle(acc)
            }
            HStack(spacing: 12) {
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
                Spacer()
            }
            .foregroundStyle(DashSkin.inkSoft(dark))
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
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
                points: dailyPoints, barColor: acc, lineColor: gold, dark: dark, scroll: true)
        }
        SkinCard(title: "Token mix by day", dark: dark) {
            StackedChart(
                bars: tokenMixBars, costLine: dailyPoints,
                domain: tokenMixDomain, range: tokenMixRange, dark: dark)
        }
        SkinCard(title: "Model usage over time", dark: dark) {
            StackedChart(
                bars: modelTimeBars, costLine: dailyPoints,
                domain: modelDomain, range: modelRange, dark: dark)
        }
        if model.allSources.count > 1 {
            SkinCard(title: "Usage by source over time", dark: dark) {
                StackedChart(
                    bars: sourceBars, costLine: dailyPoints,
                    domain: sourceDomain, range: sourceRange, dark: dark)
            }
        }
        HStack(alignment: .top, spacing: 16) {
            SkinCard(title: "By day of week", dark: dark) {
                ComboChart(
                    points: dowPoints, barColor: acc, lineColor: gold, dark: dark, height: 200)
            }
            SkinCard(title: "Share by model", dark: dark) {
                DonutChart(slices: donutSlices)
            }
        }
        if !model.projects.isEmpty {
            SkinCard(title: "By project", dark: dark) {
                VStack(alignment: .leading, spacing: 12) {
                    ComboChart(
                        points: projectPoints, barColor: acc, lineColor: gold, dark: dark,
                        height: 280)
                    ProjectDrilldownView(model: model, dark: dark)
                }
            }
        }
        SkinCard(title: "Hourly — all time", dark: dark) {
            ComboChart(
                points: hourlyPoints, barColor: acc, lineColor: gold, dark: dark, height: 200)
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
                        width: 70, alignment: .trailing)
                    Text(DashFmt.pct(m.share)).font(DashSkin.mono(11)).frame(
                        width: 60, alignment: .trailing
                    ).foregroundStyle(DashSkin.inkSoft(dark))
                    Text(DashFmt.tokens(m.tokens)).font(DashSkin.mono(11)).frame(
                        width: 70, alignment: .trailing)
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

    private var dailyPoints: [ComboPoint] {
        model.series.map {
            ComboPoint(id: $0.id, label: $0.label, tokens: $0.tokens, cost: $0.cost)
        }
    }
    private var dowPoints: [ComboPoint] {
        model.dow.map {
            ComboPoint(id: $0.label, label: $0.label, tokens: $0.tokens, cost: $0.cost)
        }
    }
    private var hourlyPoints: [ComboPoint] {
        model.hourlyAll.map {
            ComboPoint(
                id: "\($0.hour)", label: String(format: "%02d", $0.hour), tokens: $0.tokens,
                cost: $0.cost)
        }
    }
    private var projectPoints: [ComboPoint] {
        let rows = model.projects
        var points = rows.prefix(15).map {
            ComboPoint(id: $0.id, label: $0.name, tokens: $0.tokens, cost: $0.cost)
        }
        let rest = rows.dropFirst(15)
        if !rest.isEmpty {
            points.append(
                ComboPoint(
                    id: "__others", label: "others (\(rest.count))",
                    tokens: rest.reduce(0) { $0 + $1.tokens },
                    cost: rest.reduce(0) { $0 + $1.cost }))
        }
        return points
    }
    private var tokenMixBars: [StackDatum] {
        model.series.flatMap { d in
            [
                StackDatum(id: "\(d.id)-in", x: d.label, series: "input", value: d.input),
                StackDatum(id: "\(d.id)-out", x: d.label, series: "output", value: d.output),
                StackDatum(
                    id: "\(d.id)-cc", x: d.label, series: "cache write", value: d.cacheCreate),
                StackDatum(id: "\(d.id)-cr", x: d.label, series: "cache read", value: d.cacheRead),
            ]
        }
    }
    private var tokenMixDomain: [String] { ["input", "output", "cache write", "cache read"] }
    private var tokenMixRange: [Color] {
        [
            DashPalette.inputColor(dark), DashPalette.outputColor(dark),
            DashPalette.cacheCreateColor, DashPalette.cacheReadColor,
        ]
    }
    private var modelTimeBars: [StackDatum] {
        model.series.flatMap { d in
            d.byModel.map {
                StackDatum(
                    id: "\(d.id)-\($0.key)", x: d.label, series: DashFmt.shortModel($0.key),
                    value: $0.value)
            }
        }
    }
    private var modelDomain: [String] { model.allModels.map(DashFmt.shortModel) }
    private var modelRange: [Color] { model.allModels.map { model.modelColor($0, dark: dark) } }
    private var sourceBars: [StackDatum] {
        model.series.flatMap { d in
            d.bySource.map {
                StackDatum(
                    id: "\(d.id)-\($0.key)", x: d.label, series: model.sourceLabel($0.key),
                    value: $0.value)
            }
        }
    }
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
    let model: DashboardModel
    let dark: Bool
    @State private var hoveredDay: String?

    var body: some View {
        let weeks = stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0..<min($0 + 7, days.count)])
        }
        let costs = days.map(\.cost).filter { $0 > 0 }.sorted()
        let cuts =
            costs.isEmpty
            ? [0.0, 0, 0]
            : [costs[costs.count / 4], costs[costs.count / 2], costs[costs.count * 3 / 4]]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
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
                                        hoveredDay = model.heatDetail[day.id] != nil ? day.id : nil
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
                                        HeatCard(detail: detail, model: model, dark: dark)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .frame(height: 122)
    }

    private func cellColor(_ cost: Double, cuts: [Double]) -> Color {
        if cost <= 0 { return DashSkin.grid(dark) }
        if cost <= cuts[0] { return DashPalette.color("#f6d9bf") }
        if cost <= cuts[1] { return DashPalette.color("#f0b384") }
        if cost <= cuts[2] { return DashPalette.color("#e2884f") }
        return DashPalette.color("#c75e36")
    }
}
