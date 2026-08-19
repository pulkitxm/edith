import Charts
import EdithKit
import SwiftUI

struct LimitsChartView: View {
    let points: [LimitPoint]
    let theme: Color
    @AppStorage(AppStorageKeys.Limits.warnPercent, store: SharedDefaults.store) private var warn =
        LimitRing.defaultWarnPercent
    @AppStorage(AppStorageKeys.Limits.critPercent, store: SharedDefaults.store) private var crit =
        LimitRing.defaultCriticalPercent
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    struct Sample: Identifiable {
        let date: Date
        let value: Double
        let series: String
        var id: String { "\(series)-\(date.timeIntervalSince1970)" }
    }

    private var samples: [Sample] { Self.samples(from: points) }

    static func samples(from points: [LimitPoint], now: Date = Date()) -> [Sample] {
        var out: [Sample] = []
        for (key, name) in [(\LimitPoint.s, "Session"), (\LimitPoint.w, "Weekly")] {
            let pts = points.compactMap { p in p[keyPath: key].map { (p.date, $0) } }
            out += pts.map { Sample(date: $0.0, value: $0.1, series: name) }
            if let last = pts.last, last.0 < now {
                out.append(Sample(date: now, value: last.1, series: name))
            }
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(samples) { s in
                LineMark(
                    x: .value("Time", s.date),
                    y: .value("Percent", s.value),
                    series: .value("Series", s.series)
                )
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .foregroundStyle(by: .value("Series", s.series))
            }
            RuleMark(y: .value("Warning", warn))
                .foregroundStyle(DashSkin.gold.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            RuleMark(y: .value("Critical", crit))
                .foregroundStyle(DashSkin.danger.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartForegroundStyleScale(["Session": theme, "Weekly": DashSkin.inkSoft(dark)])
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) {
                AxisGridLine().foregroundStyle(DashSkin.line(dark))
                AxisValueLabel().font(.system(size: 8)).foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) {
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: 8)).foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .chartLegend(position: .top, alignment: .trailing, spacing: 4)
        .frame(height: 84)
    }
}
