import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct RateLimitsDialsView: View {
    let dark: Bool
    var fill = false
    var minHeight: CGFloat? = nil
    var showsJumpLink = false
    @AppStorage(AppStorageKeys.Limits.warnPercent, store: SharedDefaults.store) private var warn =
        LimitRing.defaultWarnPercent
    @AppStorage(AppStorageKeys.Limits.critPercent, store: SharedDefaults.store) private var crit =
        LimitRing.defaultCriticalPercent
    @Environment(\.surfacePresentation) private var presentation
    @State private var latestProviders: [LimitProvider: LimitsHistory.Latest] = [:]
    @State private var point: LimitPoint?
    @State private var allowance: GrokAllowance?
    @State private var latestLimits: LimitsTopicSnapshot?
    @AppStorage(AppStorageKeys.Limits.provider, store: SharedDefaults.store) private
        var selectedRaw =
        LimitProvider.claude.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowVisible) private var windowVisible
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    @State private var providers: [LimitProvider] = []
    @State private var reloadJob: Task<Void, Never>?
    @State private var reloadLoad = ContentLoad()

    private var selected: LimitProvider {
        get {
            let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
            return providers.contains(saved) ? saved : providers.first ?? saved
        }
        nonmutating set { selectedRaw = newValue.rawValue }
    }

    private func reload() {
        reloadJob?.cancel()
        reloadJob = Task {
            await reloadLoad.perform(operation: { await LimitsHistory.loadLatestProviders() }) {
                latest in
                latestProviders = latest
                let found = LimitProvider.allCases.filter { latest[$0] != nil }
                providers = found
                let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
                let provider = found.contains(saved) ? saved : found.first ?? saved
                allowance = latest[provider]?.grok
                point = latest[provider].map {
                    LimitPoint(
                        date: $0.date, s: $0.session?.percent, w: $0.week?.percent,
                        sessionReset: $0.session?.resetsAt, weekReset: $0.week?.resetsAt)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline) {
                if !showsJumpLink {
                    ProviderSwitchButton(
                        selection: Binding(get: { selected }, set: { selected = $0 }),
                        providers: providers, color: DashSkin.ink(dark), size: 16)
                }
                if presentation?.tile.showTitle != false {
                    Text(presentation?.tile.displayTitle ?? "Rate limits")
                        .font(DashSkin.heading(18)).foregroundStyle(DashSkin.ink(dark))
                }
                Spacer()
                Text(limitCaption)
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                LimitsRefreshButton(dark: dark) { reload() }
            }
            if showsJumpLink {
                providerOverview
            } else {
                HStack(spacing: UIScale.pt(24)) {
                    if selected == .cursor {
                        dial("CURSOR MODELS", pct: point?.s, reset: point?.sessionReset)
                        dial("OTHER MODELS", pct: point?.w, reset: point?.weekReset)
                    } else if selected == .grok {
                        dial(
                            GrokPeriod.title(allowance?.period).uppercased(), pct: point?.w,
                            reset: point?.weekReset)
                    } else {
                        dial("SESSION (5H)", pct: point?.s, reset: point?.sessionReset)
                        dial("WEEKLY", pct: point?.w, reset: point?.weekReset)
                    }
                }
                .frame(maxWidth: .infinity)
                if selected == .grok, let allowance,
                    !allowance.summary.isEmpty || allowance.extraLine != nil
                {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        if !allowance.summary.isEmpty {
                            Text(allowance.summary)
                        }
                        if let extra = allowance.extraLine {
                            Text(extra)
                        }
                    }
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let point {
                    Text("As of \(point.date.formatted(.dateTime.month().day().hour().minute()))")
                        .font(DashSkin.mono(10)).foregroundStyle(DashSkin.inkFaint(dark))
                }
                if let error = latestLimits?.providers.first(where: { $0.provider == selected })?
                    .error
                {
                    Text(error)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }

        }
        .padding(
            EdgeInsets(
                top: UIScale.pt(presentation?.padding ?? 16),
                leading: UIScale.pt(presentation?.padding ?? 16),
                bottom: UIScale.pt(presentation?.padding ?? 14),
                trailing: UIScale.pt(presentation?.padding ?? 16))
        )
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .widgetBar(
            cornerRadius: presentation?.cornerRadius ?? 16,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark),
            shadow: .black.opacity(dark ? 0.32 : 0.05)
        )
        .pageTask {
            for await _ in NotificationCenter.default.notifications(
                named: UsageEvents.limitsUpdated)
            {
                guard !Task.isCancelled else { return }
                latestLimits = UsageWorkerOperations.controller?.latestLimits
                reload()
            }
        }
        .onChange(of: selectedRaw) { if automaticActionsEnabled, windowVisible { reload() } }
        .onReceive(
            NotificationCenter.default.publisher(for: UsageEvents.limitsUpdated)
        ) { _ in
            if automaticActionsEnabled, windowVisible { reload() }
        }
        .pageRefresh(
            interval: { .seconds(60) },
            cancel: {
                reloadJob?.cancel()
                reloadLoad.cancel()
            }
        ) {
            reload()
        }
    }

    @ViewBuilder private var providerOverview: some View {
        if providers.isEmpty {
            Text("Connect a provider in Agent Usage to see its limits.")
                .font(.edithText(.callout)).foregroundStyle(.secondary)
        } else {
            SurfaceFittedGrid(count: providers.count, minimum: 240) {
                ForEach(providers) { provider in
                    if let latest = latestProviders[provider] {
                        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                            HStack(spacing: UIScale.pt(6)) {
                                ProviderLogoView(provider).frame(
                                    width: UIScale.pt(14), height: UIScale.pt(14))
                                Text(provider.label).font(.edithText(.headline))
                                Spacer(minLength: 0)
                                if let tier = latest.grok?.tier,
                                    presentation?.tile.showDetails != false,
                                    presentation?.tile.shows("account") != false
                                {
                                    Text(tier).font(.edithText(.caption)).foregroundStyle(
                                        .secondary)
                                }
                            }
                            if let session = latest.session,
                                presentation?.tile.shows("session") != false
                            {
                                quotaRow(
                                    provider == .cursor ? "Cursor models" : "Session (5h)",
                                    window: session)
                            }
                            if let week = latest.week, presentation?.tile.shows("weekly") != false {
                                quotaRow(
                                    provider == .cursor
                                        ? "Other models"
                                        : provider == .grok
                                            ? GrokPeriod.title(latest.grok?.period) : "Weekly",
                                    window: week)
                            }
                            if let fable = latest.fable,
                                presentation?.tile.shows("additional") != false
                            {
                                quotaRow("Additional models", window: fable)
                            }
                            if presentation?.tile.showDetails != false {
                                if let extra = latest.grok?.extraLine,
                                    presentation?.tile.shows("account") != false
                                {
                                    Text(extra).font(.edithText(.caption)).foregroundStyle(
                                        .secondary)
                                }
                                if presentation?.tile.shows("updated") != false {
                                    Text(
                                        "Updated \(latest.date.formatted(.relative(presentation: .numeric)))"
                                    )
                                    .font(.edithText(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(UIScale.pt(presentation?.tile.dense == true ? 8 : 12))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(
                            Color.secondary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                    }
                }
            }
        }
    }

    private func quotaRow(_ label: String, window: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack {
                Text(label).font(.edithText(.caption))
                Spacer(minLength: 0)
                Text("\(Int(window.percent))% used").font(.edithText(.caption)).monospacedDigit()
            }
            GeometryReader { proxy in
                Capsule().fill(Color.secondary.opacity(0.15))
                    .overlay(alignment: .leading) {
                        Capsule().fill(
                            presentation?.tile.accent == false
                                ? .secondary : color(for: window.percent)
                        )
                        .frame(width: proxy.size.width * max(0, min(1, window.percent / 100)))
                    }
            }.frame(height: UIScale.pt(5))
            if presentation?.tile.showDetails != false {
                HStack {
                    if presentation?.tile.shows("remaining") != false {
                        Text("\(max(0, 100 - Int(window.percent)))% remaining")
                    }
                    Spacer(minLength: 0)
                    if let reset = window.resetsAt, presentation?.tile.shows("resets") != false {
                        Text(resetText(reset))
                    }
                }.font(.edithText(.caption2)).foregroundStyle(.secondary)
            }
        }
    }

    private var limitCaption: String {
        if showsJumpLink { return "\(providers.count) connected" }
        if selected == .cursor { return "billing cycle" }
        if selected == .grok { return GrokPeriod.title(allowance?.period).lowercased() }
        return "session · weekly"
    }

    private func dial(_ label: String, pct: Double?, reset: Date?) -> some View {
        let p = pct ?? 0
        return VStack(spacing: UIScale.pt(8)) {
            ZStack {
                Circle().stroke(DashSkin.line(dark), lineWidth: UIScale.pt(8))
                Circle()
                    .trim(from: 0, to: min(p / 100, 1))
                    .stroke(
                        color(for: p), style: StrokeStyle(lineWidth: UIScale.pt(8), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(
                        Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: p)
                Text(pct != nil ? "\(Int(p))%" : "-")
                    .font(DashSkin.heading(30)).foregroundStyle(DashSkin.ink(dark))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(
                        Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                        value: pct.map { Int($0) })
            }
            .frame(width: UIScale.pt(104), height: UIScale.pt(104))
            Text(label).font(DashSkin.mono(9)).tracking(UIScale.pt(1.4))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(resetText(reset)).font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark)).lineLimit(1)
        }
    }

    private static let resetFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func resetText(_ d: Date?) -> String {
        guard let d else { return " " }
        return "Resets " + Self.resetFormatter.localizedString(for: d, relativeTo: Date())
    }

    private func color(for percent: Double) -> Color {
        LimitRing.color(percent: percent, warn: warn, critical: crit)
    }
}

struct LimitsRefreshButton: View {
    @Environment(\.windowVisible) private var windowVisible
    let dark: Bool
    var onRefreshed: () -> Void
    @State private var refreshing = false
    @State private var timeoutTask: Task<Void, Never>?

    var body: some View {
        Button {
            refreshing = true
            try? UsageWorkerOperations.requestLimitsRefresh()
            timeoutTask?.cancel()
            timeoutTask = Task {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                refreshing = false
            }
        } label: {
            Group {
                if refreshing {
                    SkeletonGroup {
                        SkeletonBlock(width: 16, height: 16, corner: 8)
                    }
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .frame(width: UIScale.pt(16), height: UIScale.pt(16))
        }
        .buttonStyle(.edith(.toolbar))
        .disabled(refreshing)
        .help("Refresh limits now")
        .onDisappear {
            timeoutTask?.cancel(); timeoutTask = nil
        }
        .pageTask {
            for await _ in NotificationCenter.default.notifications(
                named: UsageEvents.limitsUpdated)
            {
                guard !Task.isCancelled else { return }
                refreshing = false
                onRefreshed()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UsageEvents.limitsUpdated)
        ) { _ in
            refreshing = false
            onRefreshed()
        }
    }
}

struct LimitsCardView: View {
    let theme: Color
    let dark: Bool
    @AppStorage(AppStorageKeys.Limits.warnPercent, store: SharedDefaults.store) private var warn =
        LimitRing.defaultWarnPercent
    @AppStorage(AppStorageKeys.Limits.critPercent, store: SharedDefaults.store) private var crit =
        LimitRing.defaultCriticalPercent
    @State private var all: [LimitPoint] = []
    @State private var downsampled: [LimitPoint] = []
    @State private var visible: [LimitPoint] = []
    @State private var samples: [Sample] = []
    @State private var marks: [LimitResetMarker] = []
    @State private var loadedProvider: LimitProvider?
    @State private var range = "24h"
    @State private var selected: Date?
    @AppStorage(AppStorageKeys.Limits.provider, store: SharedDefaults.store) private
        var selectedProviderRaw =
        LimitProvider.claude.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var providers: [LimitProvider] = []
    @State private var reloadJob: Task<Void, Never>?
    @State private var reloadLoad = ContentLoad()

    private var selectedProvider: LimitProvider {
        get {
            let saved = LimitProvider(rawValue: selectedProviderRaw) ?? .claude
            return providers.contains(saved) ? saved : providers.first ?? saved
        }
        nonmutating set { selectedProviderRaw = newValue.rawValue }
    }

    private var sessionSeriesName: String {
        if selectedProvider == .cursor { return "Cursor models" }
        if selectedProvider == .grok { return "Allowance" }
        return "Session"
    }
    private var weekSeriesName: String {
        if selectedProvider == .cursor { return "Other models" }
        if selectedProvider == .grok { return "Allowance" }
        return "Weekly"
    }

    private var sessionC: Color { DashSkin.accent(dark) }
    private let weeklyC = DashPalette.color("#c89b3c")
    private let ranges: [(String, TimeInterval?)] = [
        ("24h", 86400), ("7d", 7 * 86400), ("30d", 30 * 86400), ("All", nil),
    ]

    struct Sample: Identifiable {
        let t: Date
        let v: Double
        let series: String
        var id: String { "\(series)-\(t.timeIntervalSince1970)" }
    }

    var body: some View {
        PageCard(
            title: selectedProvider == .cursor
                ? "Cursor models & other models"
                : selectedProvider == .grok ? "Grok allowance" : "Rate limits - session & weekly"
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                ProviderSwitchButton(
                    selection: Binding(
                        get: { selectedProvider }, set: { selectedProvider = $0 }),
                    providers: providers, color: DashSkin.ink(dark), size: 15)
                if loadedProvider == selectedProvider, all.count > 1 {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        HStack {
                            segmented
                            Spacer()
                            readout
                            LimitsRefreshButton(dark: dark) { reloadAll() }
                        }
                        chart.id(selectedProvider)
                    }
                } else {
                    HStack {
                        Text("Collecting limit history…")
                            .font(.system(size: UIScale.pt(12))).foregroundStyle(
                                DashSkin.inkFaint(dark)
                            )
                            .frame(maxWidth: .infinity, minHeight: UIScale.pt(60))
                        LimitsRefreshButton(dark: dark) { reloadAll() }
                    }
                }
            }
        }
        .pageTask(cancel: {
            reloadJob?.cancel()
            reloadLoad.cancel()
        }) { reloadAll() }
        .onChange(of: range) {
            selected = nil
            rebuildVisible()
        }
        .onChange(of: selectedProviderRaw) { reloadAll() }
    }

    private func reloadAll() {
        let preferred = LimitProvider(rawValue: selectedProviderRaw) ?? .claude
        reloadJob?.cancel()
        reloadJob = Task {
            await reloadLoad.perform(operation: {
                await LimitsHistory.loadSnapshot(preferredProvider: preferred)
            }) { snapshot in
                providers = snapshot.providers
                loadedProvider = snapshot.provider
                selected = nil
                all = snapshot.points
                let now = all.last?.date ?? Date()
                downsampled = LimitsHistory.downsample(all, now: now)
                rebuildVisible()
            }
        }
    }

    private func rebuildVisible() {
        let now = all.last?.date ?? Date()
        let window = ranges.first { $0.0 == range }?.1 ?? nil
        let display = LimitsChartDisplay.build(
            downsampled, now: now, window: window, sessionSeries: sessionSeriesName,
            weekSeries: weekSeriesName)
        visible = display.visible
        marks = display.marks
        samples = display.samples
    }

    private var segmented: some View {
        EdithSegmentedPicker(
            "Range", selection: $range, options: ranges.map { $0.0 }, label: { $0 }
        )
        .fixedSize()
    }

    private var readout: some View {
        let point = selected.flatMap { LimitsChartDisplay.nearest(in: visible, to: $0) }
        return Group {
            if let point {
                HStack(spacing: UIScale.pt(10)) {
                    Text(point.date.formatted(.dateTime.month().day().hour().minute()))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    if let s = point.s {
                        Text("\(selectedProvider == .cursor ? "models" : "S") \(Int(s))%")
                            .foregroundStyle(sessionC)
                            .contentTransition(.numericText())
                            .animation(
                                Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                                value: Int(s))
                    }
                    if let w = point.w {
                        Text("\(selectedProvider == .cursor ? "other" : "W") \(Int(w))%")
                            .foregroundStyle(weeklyC)
                            .contentTransition(.numericText())
                            .animation(
                                Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                                value: Int(w))
                    }
                }
            } else {
                Text("Drag chart to inspect").foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .font(.system(size: UIScale.pt(10.5), weight: .medium, design: .monospaced))
    }

    private var chart: some View {
        let now = all.last?.date ?? Date()
        let start = visible.first?.date ?? now
        let spanDays = now.timeIntervalSince(start) / 86400
        return Chart {
            ForEach(marks) { m in
                RuleMark(x: .value("Reset", m.date))
                    .foregroundStyle(m.session ? sessionC.opacity(0.3) : weeklyC.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [2, 3]))
            }
            RuleMark(y: .value("Warn", warn))
                .foregroundStyle(.orange.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [4, 4]))
            RuleMark(y: .value("Crit", crit))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [4, 4]))
            ForEach(samples) { s in
                LineMark(
                    x: .value("Time", s.t),
                    y: .value("Percent", s.v),
                    series: .value("Series", s.series)
                )
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1.5)))
                .foregroundStyle(by: .value("Series", s.series))
            }
        }
        .chartForegroundStyleScale(
            domain: selectedProvider == .grok
                ? [weekSeriesName] : [sessionSeriesName, weekSeriesName],
            range: selectedProvider == .grok ? [weeklyC] : [sessionC, weeklyC]
        )
        .chartYScale(domain: 0...100)
        .chartXScale(domain: start...now)
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%").font(.system(size: UIScale.pt(8)))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: spanDays < 2 ? 5 : 6)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(tick(d, spanDays: spanDays)).font(.system(size: UIScale.pt(8)))
                            .foregroundStyle(
                                .tertiary)
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: UIScale.pt(6))
        .frame(height: UIScale.pt(220))
    }

    private func tick(_ d: Date, spanDays: Double) -> String {
        let cal = Calendar.current
        if spanDays < 2 {
            return String(format: "%02d:00", cal.component(.hour, from: d))
        }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
    }
}

private enum LimitsChartDisplay {
    static let maxPointsPerSeries = 400

    struct Output {
        let visible: [LimitPoint]
        let marks: [LimitResetMarker]
        let samples: [LimitsCardView.Sample]
    }

    static func build(
        _ points: [LimitPoint], now: Date, window: TimeInterval?,
        sessionSeries: String = "Session", weekSeries: String = "Weekly"
    ) -> Output {
        var pts = points
        if let window {
            let cutoff = now.addingTimeInterval(-window)
            pts = Array(points[firstIndex(in: points, onOrAfter: cutoff)...])
        }
        let start = pts.first?.date ?? now
        let spanDays = now.timeIntervalSince(start) / 86400
        var marks: [LimitResetMarker] = []
        for mark in LimitsHistory.resetMarkers(pts) where !mark.session || spanDays <= 7 {
            marks.append(mark)
        }
        let capped = cap(pts, start: start, end: now)
        var samples: [LimitsCardView.Sample] = []
        samples.reserveCapacity(capped.count * 2)
        for point in capped {
            if let s = point.s {
                samples.append(LimitsCardView.Sample(t: point.date, v: s, series: sessionSeries))
            }
            if let w = point.w {
                samples.append(LimitsCardView.Sample(t: point.date, v: w, series: weekSeries))
            }
        }
        return Output(visible: capped, marks: marks, samples: samples)
    }

    static func firstIndex(in points: [LimitPoint], onOrAfter cutoff: Date) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < cutoff { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func cap(_ points: [LimitPoint], start: Date, end: Date) -> [LimitPoint] {
        guard points.count > maxPointsPerSeries else { return points }
        let span = max(end.timeIntervalSince(start), 1)
        let width = span / Double(maxPointsPerSeries)
        var out: [LimitPoint] = []
        out.reserveCapacity(maxPointsPerSeries + 1)
        var bucket = Int.min
        var date = start
        var maxSession: Double?
        var maxWeekly: Double?
        var sessionReset: Date?
        var weekReset: Date?
        func flush() {
            guard bucket != Int.min else { return }
            out.append(
                LimitPoint(
                    date: date, s: maxSession, w: maxWeekly, sessionReset: sessionReset,
                    weekReset: weekReset))
        }
        for point in points {
            let index = Int(point.date.timeIntervalSince(start) / width)
            if index != bucket {
                flush()
                bucket = index
                date = point.date
                maxSession = point.s
                maxWeekly = point.w
                sessionReset = point.sessionReset
                weekReset = point.weekReset
                continue
            }
            if let s = point.s { maxSession = max(maxSession ?? s, s) }
            if let w = point.w { maxWeekly = max(maxWeekly ?? w, w) }
            if let reset = point.sessionReset { sessionReset = reset }
            if let reset = point.weekReset { weekReset = reset }
        }
        flush()
        return out
    }

    static func nearest(in points: [LimitPoint], to date: Date) -> LimitPoint? {
        guard !points.isEmpty else { return nil }
        let index = firstIndex(in: points, onOrAfter: date)
        if index == points.count { return points[points.count - 1] }
        if index == 0 { return points[0] }
        let after = points[index]
        let before = points[index - 1]
        let beforeGap = date.timeIntervalSince(before.date)
        let afterGap = after.date.timeIntervalSince(date)
        return beforeGap <= afterGap ? before : after
    }
}
