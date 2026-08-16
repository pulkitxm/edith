import Charts
import EdithKit
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
    @State private var point: LimitPoint?
    @AppStorage(AppStorageKeys.Limits.provider, store: SharedDefaults.store) private
        var selectedRaw =
        LimitProvider.claude.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var providers: [LimitProvider] = []

    private var selected: LimitProvider {
        get {
            let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
            return providers.contains(saved) ? saved : providers.first ?? saved
        }
        nonmutating set { selectedRaw = newValue.rawValue }
    }

    private func reload() {
        let found = LimitsHistory.availableProviders()
        providers = found
        let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
        point = LimitsHistory.loadLatestPoint(
            provider: found.contains(saved) ? saved : found.first ?? saved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline) {
                ProviderSwitchButton(
                    selection: Binding(get: { selected }, set: { selected = $0 }),
                    providers: providers, color: DashSkin.ink(dark), size: 16)
                Text("Rate limits").font(DashSkin.serif(18)).foregroundStyle(DashSkin.ink(dark))
                Spacer()
                Text("session · weekly").font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                LimitsRefreshButton(dark: dark) { reload() }
            }
            HStack(spacing: UIScale.pt(24)) {
                dial("SESSION (5H)", pct: point?.s, reset: point?.sessionReset)
                dial("WEEKLY", pct: point?.w, reset: point?.weekReset)
            }
            .frame(maxWidth: .infinity)
            if let point {
                Text("As of \(point.date.formatted(.dateTime.hour().minute()))")
                    .font(DashSkin.mono(10)).foregroundStyle(DashSkin.inkFaint(dark))
            }
            if showsJumpLink {
                JumpLink(title: "Open Agent Usage", destination: .dashboard, dark: dark)
            }
        }
        .padding(
            EdgeInsets(
                top: UIScale.pt(16), leading: UIScale.pt(16),
                bottom: UIScale.pt(14), trailing: UIScale.pt(16))
        )
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .widgetBar(
            cornerRadius: 16,
            fill: DashSkin.paper2(dark),
            stroke: DashSkin.line(dark),
            shadow: .black.opacity(dark ? 0.32 : 0.05)
        )
        .task { reload() }
        .onChange(of: selectedRaw) { reload() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.limitsUpdated)
        ) { _ in
            reload()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            reload()
        }
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
                    .font(DashSkin.serif(30)).foregroundStyle(DashSkin.ink(dark))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(
                        Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                        value: pct.map { Int($0) })
            }
            .frame(width: UIScale.pt(104), height: UIScale.pt(104))
            Text(label).font(DashSkin.mono(9)).tracking(UIScale.pt(1.4))
                .foregroundStyle(DashSkin.inkFaint(dark))
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
    let dark: Bool
    var onRefreshed: () -> Void
    @State private var refreshing = false

    var body: some View {
        Button {
            refreshing = true
            IPC.post(IPC.Name.requestLimitsRefresh)
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                refreshing = false
            }
        } label: {
            Group {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .frame(width: UIScale.pt(16), height: UIScale.pt(16))
        }
        .buttonStyle(HoverButtonStyle())
        .disabled(refreshing)
        .help("Refresh limits now")
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: IPC.Name.limitsUpdated)
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
    @State private var range = "24h"
    @State private var selected: Date?
    @AppStorage(AppStorageKeys.Limits.provider, store: SharedDefaults.store) private
        var selectedProviderRaw =
        LimitProvider.claude.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var providers: [LimitProvider] = []

    private var selectedProvider: LimitProvider {
        get {
            let saved = LimitProvider(rawValue: selectedProviderRaw) ?? .claude
            return providers.contains(saved) ? saved : providers.first ?? saved
        }
        nonmutating set { selectedProviderRaw = newValue.rawValue }
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
        SkinCard(title: "Rate limits - session & weekly", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                ProviderSwitchButton(
                    selection: Binding(
                        get: { selectedProvider }, set: { selectedProvider = $0 }),
                    providers: providers, color: DashSkin.ink(dark), size: 15)
                if all.count > 1 {
                    VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                        HStack {
                            segmented
                            Spacer()
                            readout
                            LimitsRefreshButton(dark: dark) { reloadAll() }
                        }
                        chart
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
        .task { reloadAll() }
        .onChange(of: range) {
            selected = nil
            rebuildVisible()
        }
        .onChange(of: selectedProviderRaw) { reloadAll() }
    }

    private func reloadAll() {
        providers = LimitsHistory.availableProviders()
        all = LimitsHistory.loadAll(provider: selectedProvider)
        let now = all.last?.date ?? Date()
        downsampled = LimitsHistory.downsample(all, now: now)
        rebuildVisible()
    }

    private func rebuildVisible() {
        let now = all.last?.date ?? Date()
        let ms = ranges.first { $0.0 == range }?.1 ?? nil
        let pts =
            ms.map { m in downsampled.filter { $0.date >= now.addingTimeInterval(-m) } }
            ?? downsampled
        visible = pts
        let start = pts.first?.date ?? now
        let spanDays = now.timeIntervalSince(start) / 86400
        marks = LimitsHistory.resetMarkers(pts).filter { !$0.session || spanDays <= 7 }
        samples = pts.flatMap { p -> [Sample] in
            [
                p.s.map { Sample(t: p.date, v: $0, series: "Session") },
                p.w.map { Sample(t: p.date, v: $0, series: "Weekly") },
            ].compactMap { $0 }
        }
    }

    private var segmented: some View {
        HStack(spacing: UIScale.pt(6)) {
            ForEach(ranges, id: \.0) { name, _ in
                Button(name) { range = name }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .font(
                        .system(size: UIScale.pt(11), weight: range == name ? .semibold : .regular)
                    )
                    .padding(.horizontal, UIScale.pt(10)).padding(.vertical, UIScale.pt(4))
                    .background(
                        range == name
                            ? AnyShapeStyle(theme.opacity(0.9))
                            : AnyShapeStyle(.primary.opacity(0.06)),
                        in: Capsule()
                    )
                    .foregroundStyle(
                        range == name ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            }
        }
    }

    private var readout: some View {
        let point = selected.flatMap { d in
            visible.min(by: {
                abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d))
            })
        }
        return Group {
            if let point {
                HStack(spacing: UIScale.pt(10)) {
                    Text(point.date.formatted(.dateTime.month().day().hour().minute()))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    if let s = point.s {
                        Text("S \(Int(s))%")
                            .foregroundStyle(sessionC)
                            .contentTransition(.numericText())
                            .animation(
                                Motion.animation(Motion.settle, reduceMotion: reduceMotion),
                                value: Int(s))
                    }
                    if let w = point.w {
                        Text("W \(Int(w))%")
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
        .chartForegroundStyleScale(["Session": sessionC, "Weekly": weeklyC])
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
