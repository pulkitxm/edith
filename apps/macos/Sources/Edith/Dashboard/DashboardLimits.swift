import Charts
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
        let s: Double?
        let w: Double?
        let sr: String?
        let wr: String?
    }

    static func loadAll() -> [DashLimitPoint] {
        guard let text = try? String(contentsOf: LimitsHistory.url, encoding: .utf8) else {
            return []
        }
        let dec = JSONDecoder()
        var out: [DashLimitPoint] = []
        for line in text.split(separator: "\n") {
            guard let r = try? dec.decode(Row.self, from: Data(line.utf8)),
                let t = UsageStore.parseISO(r.ts)
            else { continue }
            out.append(
                DashLimitPoint(
                    t: t, s: r.s, w: r.w,
                    sr: r.sr.flatMap(UsageStore.parseISO), wr: r.wr.flatMap(UsageStore.parseISO)))
        }
        return out.sorted { $0.t < $1.t }
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

    static func markers(_ pts: [DashLimitPoint]) -> [ResetMarker] {
        guard pts.count > 1 else { return [] }
        var out: [ResetMarker] = []
        for i in 1..<pts.count {
            let p = pts[i - 1]
            let q = pts[i]
            if let a = p.sr, let b = q.sr, a != b { out.append(ResetMarker(t: q.t, session: true)) }
            if let a = p.wr, let b = q.wr, a != b {
                out.append(ResetMarker(t: q.t, session: false))
            }
        }
        return out
    }
}

struct LimitsCardView: View {
    let theme: Color
    let dark: Bool
    @AppStorage("warnPercent") private var warn = 60
    @AppStorage("critPercent") private var crit = 85
    @State private var all: [DashLimitPoint] = []
    @State private var range = "24h"

    private let sessionC = DashPalette.color("#d97757")
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
        SkinCard(title: "Rate limits — session & weekly", dark: dark) {
            if all.count > 1 {
                VStack(alignment: .leading, spacing: 12) {
                    segmented
                    chart
                }
            } else {
                Text("Collecting limit history…")
                    .font(.system(size: 12)).foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .task { all = DashLimits.loadAll() }
    }

    private var segmented: some View {
        HStack(spacing: 6) {
            ForEach(ranges, id: \.0) { name, _ in
                Button(name) { range = name }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: range == name ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 4)
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

    private var chart: some View {
        let now = all.last?.t ?? Date()
        let ms = ranges.first { $0.0 == range }?.1 ?? nil
        let ds = DashLimits.downsample(all, now: now)
        let pts = ms.map { m in ds.filter { $0.t >= now.addingTimeInterval(-m) } } ?? ds
        let start = pts.first?.t ?? now
        let marks = DashLimits.markers(pts).filter { !$0.session || (ms ?? .infinity) <= 7 * 86400 }
        let samples =
            pts.flatMap { p -> [Sample] in
                [
                    p.s.map { Sample(t: p.t, v: $0, series: "Session") },
                    p.w.map { Sample(t: p.t, v: $0, series: "Weekly") },
                ].compactMap { $0 }
            }
        return Chart {
            ForEach(marks) { m in
                RuleMark(x: .value("Reset", m.t))
                    .foregroundStyle(m.session ? sessionC.opacity(0.3) : weeklyC.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            RuleMark(y: .value("Warn", warn))
                .foregroundStyle(.orange.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Crit", crit))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(samples) { s in
                LineMark(
                    x: .value("Time", s.t),
                    y: .value("Percent", s.v),
                    series: .value("Series", s.series)
                )
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(by: .value("Series", s.series))
            }
        }
        .chartForegroundStyleScale(["Session": sessionC, "Weekly": weeklyC])
        .chartYScale(domain: 0...100)
        .chartXScale(domain: start...now)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%").font(.system(size: 8)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: range == "24h" ? 5 : 6)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(tick(d)).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: 6)
        .frame(height: 220)
    }

    private func tick(_ d: Date) -> String {
        let cal = Calendar.current
        if range == "24h" {
            return String(format: "%02d:00", cal.component(.hour, from: d))
        }
        return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
    }
}
