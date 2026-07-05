import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @StateObject private var model = DashboardModel()
    @AppStorage("theme") private var themeName = "accent"
    @Environment(\.colorScheme) private var scheme
    @State private var showLog = false
    @State private var hoveredDay: String?

    private var theme: Color { themeColor(themeName) }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                metaLine
                if model.loaded {
                    kpiGrid
                    controlsBar
                    if showLog { logView }
                    charts
                } else {
                    ContentUnavailableView(
                        "No usage data yet", systemImage: "chart.bar",
                        description: Text("Hit reload to run the bundled collector.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(18)
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            await model.load()
            await store.loadLimitHistory()
        }
        .onChange(of: store.updating) { _, updating in
            if !updating {
                Task {
                    await model.load()
                    await store.loadLimitHistory()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Logo.header)
                .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
            Text("USAGE OBSERVATORY")
                .font(.system(size: 13, weight: .semibold)).tracking(3)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.runUpdate()
            } label: {
                Group {
                    if store.updating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(store.updating)
            .help("Refresh usage data")
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() }
            } label: {
                Image(systemName: "terminal").foregroundStyle(showLog ? theme : .secondary)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Show collector log")
        }
    }

    private var metaLine: some View {
        Text(
            model.loaded
                ? "Updated \(model.meta.updated) · \(model.meta.totalCost) across \(model.meta.activeDays) active days · \(model.meta.totalTokens) tokens · \(model.meta.modelCount) models · \(model.meta.sourceLabels)"
                : "Loading…"
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var kpiGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10
        ) {
            ForEach(model.kpis) { kpi in
                VStack(alignment: .leading, spacing: 3) {
                    Text(kpi.label.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundStyle(.tertiary)
                    Text(kpi.value)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(kpi.hot ? AnyShapeStyle(theme) : AnyShapeStyle(.primary))
                    Text(kpi.sub).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                rangeButton("Today", .today)
                rangeButton("Yesterday", .yesterday)
                rangeButton("Week", .thisWeek)
                rangeButton("Last week", .lastWeek)
                rangeButton("Cycle", .cycle(nil))
                rangeButton("All", .all)
            }
            HStack(spacing: 10) {
                if !model.cycleOptions.isEmpty {
                    Menu {
                        ForEach(model.cycleOptions) { c in
                            Button(c.label) { model.range = .cycle(c.id) }
                        }
                    } label: {
                        Label("Cycle", systemImage: "calendar")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if !model.monthOptions.isEmpty {
                    Menu {
                        ForEach(model.monthOptions, id: \.self) { m in
                            Button(m) { model.range = .month(m) }
                        }
                    } label: {
                        Label("Month", systemImage: "calendar.badge.clock")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Stepper("Billing day \(model.billingDay)", value: $model.billingDay, in: 1...31)
                    .font(.system(size: 11)).fixedSize()
                sourceMenu
                modelMenu
                Button("Reset") { model.reset() }
                    .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(theme)
                Spacer()
            }
        }
    }

    private func rangeButton(_ title: String, _ r: DashRange) -> some View {
        let active = isActive(r)
        return Button(title) { model.range = r }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                active ? AnyShapeStyle(theme.opacity(0.9)) : AnyShapeStyle(.primary.opacity(0.06)),
                in: Capsule()
            )
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
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
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var sourceSummary: String {
        if model.selectedSources.count == model.allSources.count { return "All sources" }
        if model.selectedSources.count == 1,
            let id = model.selectedSources.first
        {
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
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var logView: some View {
        TerminalLogView(log: store.log, theme: theme, height: 150)
    }

    @ViewBuilder private var charts: some View {
        DashCard(title: "Daily usage") {
            ComboChart(points: dailyPoints, barColor: theme, lineColor: .orange, scroll: true)
        }
        DashCard(title: "Token mix by day") {
            StackedChart(
                bars: tokenMixBars, costLine: dailyPoints,
                domain: tokenMixDomain, range: tokenMixRange)
        }
        DashCard(title: "Model usage over time") {
            StackedChart(
                bars: modelTimeBars, costLine: dailyPoints,
                domain: modelDomain, range: modelRange)
        }
        if model.allSources.count > 1 {
            DashCard(title: "Usage by source over time") {
                StackedChart(
                    bars: sourceBars, costLine: dailyPoints,
                    domain: sourceDomain, range: sourceRange)
            }
        }
        HStack(alignment: .top, spacing: 14) {
            DashCard(title: "By day of week") {
                ComboChart(points: dowPoints, barColor: theme, lineColor: .orange, height: 200)
            }
            DashCard(title: "Share by model") {
                DonutChart(slices: donutSlices)
            }
        }
        if !model.projects.isEmpty {
            DashCard(title: "By project") {
                ComboChart(points: projectPoints, barColor: theme, lineColor: .orange, height: 240)
            }
        }
        DashCard(title: "Hourly — all time") {
            ComboChart(points: hourlyPoints, barColor: theme, lineColor: .orange, height: 200)
        }
        DashCard(title: "Models") { modelsTable }
        DashCard(title: "Activity") { heatmap }
        LimitsCardView(theme: theme)
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
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.vertical, 4)
            Divider()
            ForEach(model.modelTotals) { m in
                HStack(spacing: 8) {
                    Circle().fill(model.modelColor(m.model, dark: dark)).frame(width: 8, height: 8)
                    Text(DashFmt.shortModel(m.model)).font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(DashFmt.usd(m.cost)).font(.system(size: 11)).frame(
                        width: 70, alignment: .trailing)
                    Text(DashFmt.pct(m.share)).font(.system(size: 11)).frame(
                        width: 60, alignment: .trailing
                    )
                    .foregroundStyle(.secondary)
                    Text(DashFmt.tokens(m.tokens)).font(.system(size: 11)).frame(
                        width: 70, alignment: .trailing)
                    Text("\(m.days)").font(.system(size: 11)).frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider().opacity(0.4)
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
    }

    private var heatmap: some View {
        let weeks = stride(from: 0, to: model.calendarDays.count, by: 7).map {
            Array(model.calendarDays[$0..<min($0 + 7, model.calendarDays.count)])
        }
        let costs = model.calendarDays.map(\.cost).filter { $0 > 0 }.sorted()
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
                                            .primary.opacity(hoveredDay == day.id ? 0.5 : 0),
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
        if cost <= 0 { return .primary.opacity(0.08) }
        if cost <= cuts[0] { return theme.opacity(0.3) }
        if cost <= cuts[1] { return theme.opacity(0.5) }
        if cost <= cuts[2] { return theme.opacity(0.72) }
        return theme
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
        model.projects.prefix(15).map {
            ComboPoint(id: $0.id, label: $0.name, tokens: $0.tokens, cost: $0.cost)
        }
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
