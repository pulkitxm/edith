import Charts
import EdithKit
import SwiftUI

struct DashLimitPoint: Identifiable {
    let t: Date
    let s: Double?
    let w: Double?
    let sr: Date?
    let wr: Date?
    var id: TimeInterval { t.timeIntervalSince1970 }
}

struct ResetMarker: Identifiable {
    let t: Date
    let session: Bool
    var id: String { "\(t.timeIntervalSince1970)-\(session)" }
}

enum DashLimits {
    private struct Row: Decodable {
        let ts: String
        let p: LimitProvider?
        let s: Double?
        let w: Double?
        let sr: String?
        let wr: String?
    }

    static func loadAll(provider: LimitProvider = .claude) -> [DashLimitPoint] {
        guard let text = try? String(contentsOf: LimitsHistory.url, encoding: .utf8) else {
            return []
        }
        let dec = JSONDecoder()
        var out: [DashLimitPoint] = []
        for line in text.split(separator: "\n") {
            guard let r = try? dec.decode(Row.self, from: Data(line.utf8)),
                let t = EdithDate.parseISO(r.ts), (r.p ?? .claude) == provider
            else { continue }
            out.append(
                DashLimitPoint(
                    t: t, s: r.s, w: r.w,
                    sr: r.sr.flatMap(EdithDate.parseISO), wr: r.wr.flatMap(EdithDate.parseISO)))
        }
        return out.sorted { $0.t < $1.t }
    }

    static func loadLatest(provider: LimitProvider = .claude) -> DashLimitPoint? {
        let text = FileTail.read(LimitsHistory.url, maxBytes: 8192)
        let dec = JSONDecoder()
        for line in text.split(separator: "\n").reversed() {
            guard let r = try? dec.decode(Row.self, from: Data(line.utf8)),
                let t = EdithDate.parseISO(r.ts), (r.p ?? .claude) == provider
            else { continue }
            return DashLimitPoint(
                t: t, s: r.s, w: r.w,
                sr: r.sr.flatMap(EdithDate.parseISO), wr: r.wr.flatMap(EdithDate.parseISO))
        }
        return nil
    }

    static func availableProviders() -> [LimitProvider] {
        let text = FileTail.read(LimitsHistory.url, maxBytes: 65_536)
        let decoder = JSONDecoder()
        let found = Set(
            text.split(separator: "\n").compactMap { line in
                (try? decoder.decode(Row.self, from: Data(line.utf8))).map { $0.p ?? .claude }
            })
        return LimitProvider.allCases.filter(found.contains)
    }

    static func downsample(_ rows: [DashLimitPoint], now: Date, rawWindow: TimeInterval = 7 * 86400)
        -> [DashLimitPoint]
    {
        let cutoff = now.addingTimeInterval(-rawWindow)
        var buckets: [TimeInterval: DashLimitPoint] = [:]
        var raw: [DashLimitPoint] = []
        for r in rows {
            if r.t >= cutoff {
                raw.append(r)
                continue
            }
            let b = (r.t.timeIntervalSince1970 / 3600).rounded(.down) * 3600
            if let cur = buckets[b] {
                buckets[b] = DashLimitPoint(
                    t: Date(timeIntervalSince1970: b),
                    s: [cur.s, r.s].compactMap { $0 }.max(),
                    w: [cur.w, r.w].compactMap { $0 }.max(),
                    sr: r.sr, wr: r.wr)
            } else {
                buckets[b] = DashLimitPoint(
                    t: Date(timeIntervalSince1970: b), s: r.s, w: r.w, sr: r.sr, wr: r.wr)
            }
        }
        return (Array(buckets.values) + raw).sorted { $0.t < $1.t }
    }

    static func markers(_ pts: [DashLimitPoint], minGap: TimeInterval = 20 * 60) -> [ResetMarker] {
        guard pts.count > 1 else { return [] }
        var out: [ResetMarker] = []
        var lastSession: Date?
        var lastWeekly: Date?
        for i in 1..<pts.count {
            let p = pts[i - 1]
            let q = pts[i]
            if let a = p.sr, let b = q.sr, a != b,
                lastSession.map({ q.t.timeIntervalSince($0) > minGap }) ?? true
            {
                out.append(ResetMarker(t: q.t, session: true))
                lastSession = q.t
            }
            if let a = p.wr, let b = q.wr, a != b,
                lastWeekly.map({ q.t.timeIntervalSince($0) > minGap }) ?? true
            {
                out.append(ResetMarker(t: q.t, session: false))
                lastWeekly = q.t
            }
        }
        return out
    }
}

struct RateLimitsDialsView: View {
    let dark: Bool
    var fill = false
    var minHeight: CGFloat? = nil
    var showsJumpLink = false
    @AppStorage(AppStorageKeys.Limits.warnPercent, store: SharedDefaults.store) private var warn =
        LimitRing.defaultWarnPercent
    @AppStorage(AppStorageKeys.Limits.critPercent, store: SharedDefaults.store) private var crit =
        LimitRing.defaultCriticalPercent
    @State private var point: DashLimitPoint?
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
        let found = DashLimits.availableProviders()
        providers = found
        let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
        point = DashLimits.loadLatest(
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
                dial("SESSION (5H)", pct: point?.s, reset: point?.sr)
                dial("WEEKLY", pct: point?.w, reset: point?.wr)
            }
            .frame(maxWidth: .infinity)
            if let point {
                Text("As of \(point.t.formatted(.dateTime.hour().minute()))")
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
        .frame(
            maxWidth: .infinity, minHeight: minHeight, maxHeight: fill ? .infinity : nil,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(cornerRadius: UIScale.pt(16))
                .fill(DashSkin.paper2(dark))
                .shadow(color: .black.opacity(dark ? 0.32 : 0.05), radius: UIScale.pt(12), y: 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(16)).strokeBorder(
                DashSkin.line(dark), lineWidth: UIScale.pt(1))
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
    @State private var all: [DashLimitPoint] = []
    @State private var downsampled: [DashLimitPoint] = []
    @State private var visible: [DashLimitPoint] = []
    @State private var samples: [Sample] = []
    @State private var marks: [ResetMarker] = []
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
        providers = DashLimits.availableProviders()
        all = DashLimits.loadAll(provider: selectedProvider)
        let now = all.last?.t ?? Date()
        downsampled = DashLimits.downsample(all, now: now)
        rebuildVisible()
    }

    private func rebuildVisible() {
        let now = all.last?.t ?? Date()
        let ms = ranges.first { $0.0 == range }?.1 ?? nil
        let pts =
            ms.map { m in downsampled.filter { $0.t >= now.addingTimeInterval(-m) } }
            ?? downsampled
        visible = pts
        let start = pts.first?.t ?? now
        let spanDays = now.timeIntervalSince(start) / 86400
        marks = DashLimits.markers(pts).filter { !$0.session || spanDays <= 7 }
        samples = pts.flatMap { p -> [Sample] in
            [
                p.s.map { Sample(t: p.t, v: $0, series: "Session") },
                p.w.map { Sample(t: p.t, v: $0, series: "Weekly") },
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
            visible.min(by: { abs($0.t.timeIntervalSince(d)) < abs($1.t.timeIntervalSince(d)) })
        }
        return Group {
            if let point {
                HStack(spacing: UIScale.pt(10)) {
                    Text(point.t.formatted(.dateTime.month().day().hour().minute()))
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
        let now = all.last?.t ?? Date()
        let start = visible.first?.t ?? now
        let spanDays = now.timeIntervalSince(start) / 86400
        return Chart {
            ForEach(marks) { m in
                RuleMark(x: .value("Reset", m.t))
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
