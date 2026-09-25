import Charts
import EdithKit
import SwiftUI

struct AttentionRibbonBlock: Identifiable, Equatable {
    var id: Date { start }
    var start: Date
    var end: Date
    var kind: AttentionCategoryKind
    var names: [String: TimeInterval]
    var top: AttentionSpan

    var duration: TimeInterval { end.timeIntervalSince(start) }

    static func blocks(
        _ spans: [AttentionSpan], settings: AttentionSettings, gap: TimeInterval = 60
    ) -> [AttentionRibbonBlock] {
        var blocks: [AttentionRibbonBlock] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            let kind = settings.category(span.categoryID).kind
            if var last = blocks.last, last.kind == kind,
                span.start.timeIntervalSince(last.end) <= gap
            {
                last.end = max(last.end, span.end)
                last.names[span.name, default: 0] += span.duration
                if span.duration > last.top.duration { last.top = span }
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(
                    AttentionRibbonBlock(
                        start: span.start, end: span.end, kind: kind,
                        names: [span.name: span.duration], top: span))
            }
        }
        return blocks
    }
}

struct AttentionDayRibbon: View {
    let spans: [AttentionSpan]
    let settings: AttentionSettings
    let day: DateInterval
    var height: CGFloat = 46
    @State private var selected: Date?
    @Environment(\.colorScheme) private var scheme

    static func visibleRange(_ dates: [Date], day: DateInterval, calendar: Calendar = .current)
        -> ClosedRange<Date>
    {
        guard let first = dates.min(), let last = dates.max() else { return day.start...day.end }
        let start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let end = calendar.dateInterval(of: .hour, for: last)?.end ?? last
        let lower = max(day.start, start.addingTimeInterval(-3_600))
        let upper = min(day.end, max(end.addingTimeInterval(3_600), lower.addingTimeInterval(21_600)))
        return lower...upper
    }

    var body: some View {
        let dark = scheme == .dark
        let blocks = AttentionRibbonBlock.blocks(spans, settings: settings)
        let range = Self.visibleRange(spans.flatMap { [$0.start, $0.end] }, day: day)
        let hours = range.upperBound.timeIntervalSince(range.lowerBound) / 3_600
        let hovered = selected.flatMap { date in
            blocks.first { $0.start <= date && date < $0.end }
        }
        Chart {
            ForEach(blocks) { block in
                RectangleMark(
                    xStart: .value("Start", block.start), xEnd: .value("End", block.end),
                    yStart: .value("Low", 0), yEnd: .value("High", 1)
                )
                .foregroundStyle(AttentionPalette.kind(block.kind, dark: dark))
                .opacity(hovered == nil || hovered == block ? 1 : 0.45)
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.start.addingTimeInterval(hovered.duration / 2)))
                    .foregroundStyle(.clear)
                    .annotation(
                        position: .top, spacing: UIScale.pt(4),
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        AttentionRibbonTooltip(block: hovered, settings: settings)
                    }
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hours > 13 ? 2 : 1)) { _ in
                AxisGridLine().foregroundStyle(DashSkin.grid(dark))
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: UIScale.pt(height))
        .padding(.top, UIScale.pt(hovered == nil ? 0 : 42))
        .accessibilityLabel("Timeline of the day by category")
    }
}

private struct AttentionRibbonTooltip: View {
    let block: AttentionRibbonBlock
    let settings: AttentionSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(
                "\(AttentionFormat.time(block.start)) to \(AttentionFormat.time(block.end)) · \(AttentionFormat.duration(block.duration))"
            )
            .font(.system(size: UIScale.pt(9.5)))
            .foregroundStyle(DashSkin.inkFaint(dark))
            ForEach(
                block.names.sorted { $0.value > $1.value }.prefix(3).map(\.key), id: \.self
            ) { name in
                Text(name).font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(DashSkin.ink(dark)).lineLimit(1)
            }
            if let detail = block.top.detail, !detail.isEmpty {
                Text(detail).font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkSoft(dark)).lineLimit(1)
            }
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(6))
        .frame(maxWidth: UIScale.pt(280), alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DashSkin.lineStrong(dark)))
    }
}

struct AttentionKindLegend: View {
    let kinds: [String: TimeInterval]
    let total: TimeInterval
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: UIScale.pt(14)) {
            ForEach(AttentionPalette.kinds, id: \.self) { kind in
                let value = kinds[kind.rawValue] ?? 0
                if value > 0 {
                    HStack(spacing: UIScale.pt(5)) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AttentionPalette.kind(kind, dark: dark))
                            .frame(width: UIScale.pt(9), height: UIScale.pt(9))
                        Text(kind.title)
                            .foregroundStyle(DashSkin.inkSoft(dark))
                        Text(
                            "\(AttentionFormat.duration(value)) · \(AttentionFormat.percent(value, of: total))"
                        )
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .monospacedDigit()
                    }
                    .font(.system(size: UIScale.pt(11)))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AttentionKindValue: Identifiable {
    var id: String { "\(bucket.timeIntervalSinceReferenceDate)|\(kind.rawValue)" }
    var bucket: Date
    var kind: AttentionCategoryKind
    var minutes: Double
}

struct AttentionDailyStack: View {
    let days: [AttentionDayTotal]
    let settings: AttentionSettings
    var height: CGFloat = 190
    @State private var selected: Date?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let values = days.flatMap { day in
            AttentionPalette.kinds.compactMap { kind -> AttentionKindValue? in
                let seconds = day.categories.reduce(0) {
                    settings.category($1.key).kind == kind ? $0 + $1.value : $0
                }
                guard seconds > 0 else { return nil }
                return AttentionKindValue(bucket: day.day, kind: kind, minutes: seconds / 60)
            }
        }
        let hovered = selected.flatMap { date in
            days.first { Calendar.current.isDate($0.day, inSameDayAs: date) }
        }
        Chart {
            ForEach(values) { value in
                BarMark(
                    x: .value("Day", value.bucket, unit: .day),
                    y: .value("Minutes", value.minutes)
                )
                .foregroundStyle(AttentionPalette.kind(value.kind, dark: dark))
                .cornerRadius(2)
                .opacity(hovered == nil || Calendar.current.isDate(value.bucket, inSameDayAs: hovered!.day) ? 1 : 0.5)
            }
            if let hovered {
                RuleMark(x: .value("Day", hovered.day, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(
                        position: .top, spacing: UIScale.pt(4),
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        AttentionDayTooltip(day: hovered, settings: settings)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(DashSkin.grid(dark))
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(AttentionFormat.duration(minutes * 60))
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days.count > 10 ? 5 : 1)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: UIScale.pt(height))
    }
}

private struct AttentionDayTooltip: View {
    let day: AttentionDayTotal
    let settings: AttentionSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(day.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.system(size: UIScale.pt(10), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text("\(AttentionFormat.duration(day.active)) active · \(day.switches) switches")
                .font(.system(size: UIScale.pt(10)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            if day.agentWorking > 0 {
                Text("\(AttentionFormat.duration(day.agentWorking)) agent work")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
        .padding(.horizontal, UIScale.pt(8))
        .padding(.vertical, UIScale.pt(6))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DashSkin.lineStrong(dark)))
    }
}

private struct AttentionHourValue: Identifiable {
    var id: String { "\(hour)|\(kind.rawValue)" }
    var hour: Int
    var kind: AttentionCategoryKind
    var minutes: Double
}

struct AttentionHourBars: View {
    let cells: [AttentionHourCell]
    var height: CGFloat = 160
    @State private var selected: Int?
    @Environment(\.colorScheme) private var scheme

    private var byHour: [Int: [String: TimeInterval]] {
        var result: [Int: [String: TimeInterval]] = [:]
        for cell in cells {
            for (kind, seconds) in cell.kinds {
                result[cell.hour, default: [:]][kind, default: 0] += seconds
            }
        }
        return result
    }

    var body: some View {
        let dark = scheme == .dark
        let byHour = byHour
        let values = byHour.flatMap { hour, kinds in
            AttentionPalette.kinds.compactMap { kind -> AttentionHourValue? in
                guard let seconds = kinds[kind.rawValue], seconds > 0 else { return nil }
                return AttentionHourValue(hour: hour, kind: kind, minutes: seconds / 60)
            }
        }
        Chart {
            ForEach(values) { value in
                BarMark(
                    x: .value("Hour", value.hour), y: .value("Minutes", value.minutes),
                    width: .fixed(UIScale.pt(14)))
                    .foregroundStyle(AttentionPalette.kind(value.kind, dark: dark))
                    .cornerRadius(2)
                    .opacity(selected == nil || selected == value.hour ? 1 : 0.5)
            }
            if let selected, let kinds = byHour[selected] {
                RuleMark(x: .value("Hour", selected))
                    .foregroundStyle(.clear)
                    .annotation(
                        position: .top, spacing: UIScale.pt(4),
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(String(format: "%02d:00", selected))
                                .font(.system(size: UIScale.pt(10), weight: .semibold))
                            ForEach(AttentionPalette.kinds, id: \.self) { kind in
                                if let seconds = kinds[kind.rawValue], seconds >= 30 {
                                    Text("\(kind.title) \(AttentionFormat.duration(seconds))")
                                        .font(.system(size: UIScale.pt(10)))
                                }
                            }
                        }
                        .foregroundStyle(DashSkin.ink(dark))
                        .padding(UIScale.pt(6))
                        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DashSkin.lineStrong(dark)))
                    }
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(String(format: "%02d", hour))
                            .font(.system(size: UIScale.pt(9.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(DashSkin.grid(dark))
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(AttentionFormat.duration(minutes * 60))
                            .font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: UIScale.pt(height))
    }
}

struct AttentionWeekHeatmap: View {
    let cells: [AttentionHourCell]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let byKey = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0) })
        let peak = max(cells.map(\.active).max() ?? 1, 1)
        let order = Array(Calendar.current.firstWeekday...7) + Array(1..<Calendar.current.firstWeekday)
        let symbols = Calendar.current.shortWeekdaySymbols
        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
            ForEach(order, id: \.self) { weekday in
                HStack(spacing: UIScale.pt(3)) {
                    Text(symbols[weekday - 1])
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(width: UIScale.pt(28), alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let cell = byKey[weekday * 24 + hour]
                        let active = cell?.active ?? 0
                        let focus = cell?.duration(.focus) ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                active > 0
                                    ? AttentionPalette.kind(.focus, dark: dark)
                                        .opacity(0.15 + 0.85 * active / peak)
                                    : DashSkin.grid(dark)
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: UIScale.pt(16))
                            .help(
                                "\(symbols[weekday - 1]) \(String(format: "%02d:00", hour)) · \(AttentionFormat.duration(active)) active, \(AttentionFormat.duration(focus)) productive"
                            )
                    }
                }
            }
            HStack(spacing: UIScale.pt(3)) {
                Color.clear.frame(width: UIScale.pt(28), height: 1)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 3 == 0 ? String(format: "%02d", hour) : "")
                        .font(.system(size: UIScale.pt(8.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityLabel("Active time by weekday and hour")
    }
}

struct AttentionCategoryDonut: View {
    let categories: [AttentionCategoryTotal]
    let total: TimeInterval
    var onSelect: (String) -> Void = { _ in }
    @State private var selected: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shown = Array(categories.prefix(8))
        let rest = categories.dropFirst(8).reduce(0) { $0 + $1.duration }
        let hovered = selected.flatMap { value -> AttentionCategoryTotal? in
            var running = 0.0
            for item in shown {
                running += item.duration / 60
                if value <= running { return item }
            }
            return nil
        }
        Chart {
            ForEach(shown) { item in
                SectorMark(
                    angle: .value("Minutes", item.duration / 60), innerRadius: .ratio(0.64),
                    angularInset: 1.5
                )
                .cornerRadius(3)
                .foregroundStyle(AttentionPalette.category(item.category, dark: dark))
                .opacity(hovered == nil || hovered?.id == item.id ? 1 : 0.4)
            }
            if rest > 0 {
                SectorMark(
                    angle: .value("Minutes", rest / 60), innerRadius: .ratio(0.64),
                    angularInset: 1.5
                )
                .foregroundStyle(DashSkin.grid(dark))
            }
        }
        .chartAngleSelection(value: $selected)
        .chartBackground { _ in
            VStack(spacing: UIScale.pt(1)) {
                Text(AttentionFormat.duration(hovered?.duration ?? total))
                    .font(DashSkin.heading(17))
                    .foregroundStyle(DashSkin.ink(dark))
                    .monospacedDigit()
                Text(hovered?.category.name ?? "active")
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
            .frame(maxWidth: UIScale.pt(100))
        }
        .accessibilityLabel("Time by category")
    }
}

struct AttentionConcurrencyChart: View {
    let points: [AttentionConcurrencyPoint]
    var domain: ClosedRange<Date>?
    var height: CGFloat = 120
    @State private var selected: Date?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let color = DashPalette.color(dark ? "#9085e9" : "#4a3aa7")
        let hovered = selected.flatMap { date in points.last { $0.start <= date } }
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.start), y: .value("Agents", point.working))
                    .foregroundStyle(color.opacity(0.22))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", point.start), y: .value("Agents", point.working))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd)
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.start))
                    .foregroundStyle(DashSkin.lineStrong(dark))
                    .annotation(
                        position: .top, spacing: UIScale.pt(4),
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(hovered.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: UIScale.pt(9.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(String(format: "%.1f agents working", hovered.working))
                                .font(.system(size: UIScale.pt(10.5), weight: .semibold))
                            Text("you: \(AttentionFormat.duration(hovered.attention)) active")
                                .font(.system(size: UIScale.pt(10)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                        .foregroundStyle(DashSkin.ink(dark))
                        .padding(UIScale.pt(6))
                        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DashSkin.lineStrong(dark)))
                    }
            }
        }
        .chartXScale(domain: domain ?? (points.first?.start ?? .now)...(points.last?.start ?? .now))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(DashSkin.grid(dark))
                AxisValueLabel().font(.system(size: UIScale.pt(9)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: UIScale.pt(9.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: UIScale.pt(height))
        .accessibilityLabel("Agents working over time")
    }
}
