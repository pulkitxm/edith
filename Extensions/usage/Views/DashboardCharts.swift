import Charts
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

private func costScale(_ points: [ComboPoint]) -> Double {
    let maxTok = max(points.map(\.tokens).max() ?? 0, 1)
    let maxCost = max(points.map(\.cost).max() ?? 0, 0.0001)
    return maxTok / maxCost
}

struct ChartWarmup: View {
    private static let points = [
        ComboPoint(id: "a", label: "a", tokens: 2, cost: 1),
        ComboPoint(id: "b", label: "b", tokens: 1, cost: 2),
    ]

    private static let bars = [
        StackDatum(id: "a-x", x: "a", series: "x", value: 1),
        StackDatum(id: "b-x", x: "b", series: "x", value: 2),
    ]

    var body: some View {
        VStack {
            ComboChart(points: Self.points, barColor: .clear, lineColor: .clear, height: 40)
            StackedChart(
                bars: Self.bars, costLine: Self.points, domain: ["x"], range: [.clear], height: 40)
        }
        .frame(width: 1, height: 1)
        .clipped()
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum ChartCategoryAxis {
    static let barInset = 0.11

    static func barStart(_ index: Int) -> Double { Double(index) - 0.5 + barInset }

    static func barEnd(_ index: Int) -> Double { Double(index) + 0.5 - barInset }

    static func labelStep(count: Int) -> Int { count > 30 ? 2 : 1 }

    static func index(of selection: Double?, count: Int) -> Int? {
        guard let selection, count > 0 else { return nil }
        let index = Int(selection.rounded())
        return (0..<count).contains(index) ? index : nil
    }

    static func domain(count: Int) -> ClosedRange<Double> {
        -0.5...(Double(max(count, 1)) - 0.5)
    }

    static func labelValues(count: Int) -> [Int] {
        Array(stride(from: 0, to: count, by: labelStep(count: count)))
    }
}

struct ChartStackSegment: Identifiable {
    let id: String
    let index: Int
    let series: String
    let start: Double
    let end: Double

    static func stack(_ bars: [StackDatum], labels: [String]) -> [ChartStackSegment] {
        let positions = Dictionary(
            labels.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var totals: [Int: Double] = [:]
        return bars.compactMap { datum in
            guard let index = positions[datum.x] else { return nil }
            let start = totals[index] ?? 0
            totals[index] = start + datum.value
            return ChartStackSegment(
                id: datum.id, index: index, series: datum.series, start: start,
                end: start + datum.value)
        }
    }
}

struct ComboChart: View {
    let points: [ComboPoint]
    let barColor: Color
    let lineColor: Color
    var dark = false
    var scroll = false
    var height: CGFloat = 200
    var blur = false
    var blurTokens = false
    @State private var selected: Double?

    private var selectedIndex: Int? {
        ChartCategoryAxis.index(of: selected, count: points.count)
    }

    var body: some View {
        let scale = costScale(points)
        let chart = Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, p in
                RectangleMark(
                    xStart: .value("Day", ChartCategoryAxis.barStart(index)),
                    xEnd: .value("Day", ChartCategoryAxis.barEnd(index)),
                    yStart: .value("Tokens", 0),
                    yEnd: .value("Tokens", p.tokens)
                )
                .foregroundStyle(barColor.opacity(0.7))
                .cornerRadius(2)
            }
            ForEach(Array(points.enumerated()), id: \.element.id) { index, p in
                LineMark(
                    x: .value("Day", index),
                    y: .value("Cost", p.cost * scale)
                )
                .foregroundStyle(lineColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1.5)))
            }
            if let index = selectedIndex {
                let p = points[index]
                RectangleMark(
                    xStart: .value("Day", Double(index) - 0.5),
                    xEnd: .value("Day", Double(index) + 0.5)
                )
                .foregroundStyle(.primary.opacity(0.06))
                RuleMark(x: .value("Day", index))
                    .foregroundStyle(.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [3, 3]))
                    .annotation(
                        position: .top, alignment: .center, spacing: UIScale.pt(6),
                        overflowResolution: .init(
                            x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        PointTooltip(
                            label: p.label, tokens: p.tokens, cost: p.cost, blur: blur,
                            blurTokens: blurTokens)
                    }
            }
        }
        .chartXScale(domain: ChartCategoryAxis.domain(count: points.count))
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.tokens(d)).font(.system(size: UIScale.pt(9))).foregroundStyle(
                            DashSkin.inkSoft(dark)
                        ).presenterBlur(blurTokens)
                    }
                }
            }
            AxisMarks(position: .trailing) { value in
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.usd(d / scale)).font(.system(size: UIScale.pt(9)))
                            .foregroundStyle(
                                lineColor
                            ).presenterBlur(blur)
                    }
                }
            }
        }
        .chartXAxis { categoryLabels(points.map(\.label), dark: dark) }
        .chartXSelection(value: $selected)
        .frame(height: height)
        .padding(.top, UIScale.pt(22))

        if scroll, points.count > 30 {
            chart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 30)
        } else {
            chart
        }
    }
}

@AxisContentBuilder
func categoryLabels(_ labels: [String], dark: Bool) -> some AxisContent {
    AxisMarks(values: ChartCategoryAxis.labelValues(count: labels.count)) { value in
        AxisValueLabel(orientation: .verticalReversed) {
            if let index = value.as(Int.self), labels.indices.contains(index) {
                Text(labels[index])
                    .font(.system(size: UIScale.pt(10.5))).foregroundStyle(DashSkin.ink(dark))
            }
        }
    }
}

struct PointTooltip: View {
    let label: String
    let tokens: Double
    let cost: Double
    var blur = false
    var blurTokens = false
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text(label).font(.system(size: UIScale.pt(9))).foregroundStyle(.secondary)
            Text(DashFmt.tokens(tokens)).font(.system(size: UIScale.pt(11), weight: .semibold))
                .presenterBlur(blurTokens)
            Text(DashFmt.usdFull(cost)).font(.system(size: UIScale.pt(10))).foregroundStyle(
                .secondary
            )
            .presenterBlur(blur)
        }
        .padding(.horizontal, UIScale.pt(8)).padding(.vertical, UIScale.pt(5))
        .background(DashSkin.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(7)).strokeBorder(.primary.opacity(0.12)))
    }
}

struct ChartLegendItem: Identifiable {
    let id: String
    let label: String
    let color: Color
}

enum DashboardChartLayout {
    static let visibleModelRows = 8
    static let modelRowHeight: CGFloat = 30
}

func chartSeriesDomain(_ bars: [StackDatum]) -> [String] {
    var seen: Set<String> = []
    return bars.compactMap { datum in
        seen.insert(datum.series).inserted ? datum.series : nil
    }
}

struct AdaptiveChartLegend: View {
    let items: [ChartLegendItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
                .frame(maxWidth: .infinity, alignment: .center)
            ScrollView(.horizontal, showsIndicators: false) {
                row
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: UIScale.pt(18))
    }

    private var row: some View {
        HStack(spacing: UIScale.pt(12)) {
            ForEach(items) { item in
                HStack(spacing: UIScale.pt(5)) {
                    Circle()
                        .fill(item.color)
                        .frame(width: UIScale.pt(7), height: UIScale.pt(7))
                    Text(item.label)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct StackedChart: View {
    let bars: [StackDatum]
    let costLine: [ComboPoint]
    let domain: [String]
    let range: [Color]
    var dark = false
    var scroll = true
    var height: CGFloat = 200
    var blur = false
    var blurTokens = false
    @State private var selected: Double?

    private var selectedIndex: Int? {
        ChartCategoryAxis.index(of: selected, count: costLine.count)
    }

    private var legendItems: [ChartLegendItem] {
        zip(domain, range).map { series, color in
            ChartLegendItem(id: series, label: series, color: color)
        }
    }

    var body: some View {
        let scale = costScale(costLine)
        let segments = ChartStackSegment.stack(bars, labels: costLine.map(\.label))
        let chart = Chart {
            ForEach(segments) { segment in
                RectangleMark(
                    xStart: .value("Day", ChartCategoryAxis.barStart(segment.index)),
                    xEnd: .value("Day", ChartCategoryAxis.barEnd(segment.index)),
                    yStart: .value("Tokens", segment.start),
                    yEnd: .value("Tokens", segment.end)
                )
                .foregroundStyle(by: .value("Series", segment.series))
            }
            ForEach(Array(costLine.enumerated()), id: \.element.id) { index, p in
                LineMark(
                    x: .value("Day", index),
                    y: .value("Cost", p.cost * scale)
                )
                .foregroundStyle(.secondary)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1.2)))
            }
            if let index = selectedIndex {
                let p = costLine[index]
                RectangleMark(
                    xStart: .value("Day", Double(index) - 0.5),
                    xEnd: .value("Day", Double(index) + 0.5)
                )
                .foregroundStyle(.primary.opacity(0.06))
                RuleMark(x: .value("Day", index))
                    .foregroundStyle(.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [3, 3]))
                    .annotation(
                        position: .top, alignment: .center, spacing: UIScale.pt(6),
                        overflowResolution: .init(
                            x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        PointTooltip(
                            label: p.label, tokens: p.tokens, cost: p.cost, blur: blur,
                            blurTokens: blurTokens)
                    }
            }
        }
        .chartXScale(domain: ChartCategoryAxis.domain(count: costLine.count))
        .chartXSelection(value: $selected)
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.tokens(d)).font(.system(size: UIScale.pt(9))).foregroundStyle(
                            DashSkin.inkSoft(dark)
                        ).presenterBlur(blurTokens)
                    }
                }
            }
        }
        .chartXAxis { categoryLabels(costLine.map(\.label), dark: dark) }
        .chartLegend(.hidden)
        .frame(height: max(UIScale.pt(150), height - UIScale.pt(24)))
        .padding(.top, UIScale.pt(22))

        VStack(spacing: UIScale.pt(6)) {
            if scroll, costLine.count > 30 {
                chart
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: 30)
            } else {
                chart
            }
            AdaptiveChartLegend(items: legendItems)
        }
        .frame(height: height)
    }
}

struct DonutSlice: Identifiable {
    let id: String
    let label: String
    let value: Double
    let color: Color
}

func donutSlice(at value: Double, in slices: [DonutSlice]) -> DonutSlice? {
    var acc = 0.0
    for s in slices {
        acc += s.value
        if value < acc { return s }
    }
    return slices.last
}

func donutTotal(_ slices: [DonutSlice]) -> Double {
    slices.reduce(0) { $0 + $1.value }
}

func compactDonutSlices(
    _ slices: [DonutSlice], limit: Int = DashboardComputation.stackedSeriesLimit,
    otherColor: Color
) -> [DonutSlice] {
    let ranked = slices.sorted {
        if $0.value != $1.value { return $0.value > $1.value }
        return $0.label < $1.label
    }
    guard ranked.count > limit else { return ranked }
    let kept = Array(ranked.prefix(limit))
    let other = ranked.dropFirst(limit).reduce(0) { $0 + $1.value }
    return kept + [DonutSlice(id: "__other", label: "Other", value: other, color: otherColor)]
}

struct DonutChart: View {
    let slices: [DonutSlice]
    var height: CGFloat = 220
    var blurTokens = false
    @State private var angle: Double?

    private var selected: DonutSlice? {
        angle.flatMap { donutSlice(at: $0, in: slices) }
    }

    var body: some View {
        let total = donutTotal(slices)
        let percentageTotal = max(total, 1)
        let chart = Chart(slices) { s in
            SectorMark(
                angle: .value("Tokens", s.value),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(by: .value("Model", s.label))
            .opacity(selected == nil || selected?.id == s.id ? 1 : 0.3)
        }
        .chartAngleSelection(value: $angle)
        .chartForegroundStyleScale(
            domain: slices.map(\.label), range: slices.map(\.color)
        )
        .chartLegend(.hidden)
        .overlay {
            VStack(spacing: UIScale.pt(1)) {
                if let s = selected {
                    Text(s.label)
                        .font(.system(size: UIScale.pt(10), weight: .medium)).foregroundStyle(
                            .secondary
                        )
                        .lineLimit(1)
                    Text(DashFmt.tokens(s.value)).font(
                        .system(size: UIScale.pt(13), weight: .semibold)
                    )
                    .presenterBlur(blurTokens)
                    Text(DashFmt.pct(s.value / percentageTotal)).font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(DashFmt.tokens(total)).font(
                        .system(size: UIScale.pt(13), weight: .semibold)
                    )
                    .presenterBlur(blurTokens)
                    Text("tokens").font(.system(size: UIScale.pt(8))).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: UIScale.pt(110))
            .allowsHitTesting(false)
        }

        VStack(spacing: UIScale.pt(6)) {
            chart
                .frame(height: max(UIScale.pt(150), height - UIScale.pt(24)))
            AdaptiveChartLegend(
                items: slices.map {
                    ChartLegendItem(id: $0.id, label: $0.label, color: $0.color)
                })
        }
        .frame(height: height)
    }
}

struct HeatCard: View {
    let detail: HeatDay
    let model: DashboardModel
    let dark: Bool
    var blur = false
    var blurTokens = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text(DashboardModel.ymd.string(from: detail.date))
                .font(.system(size: UIScale.pt(11), weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: UIScale.pt(5)) {
                Text("\(DashFmt.tokens(detail.tokens)) tokens")
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                    .presenterBlur(blurTokens)
                Text("· \(DashFmt.usdFull(detail.cost))")
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                    .presenterBlur(blur)
            }
            HStack(spacing: UIScale.pt(5)) {
                if detail.projCount > 0 { chip("\(detail.projCount) proj") }
                if detail.chatCount > 0 { chip("\(detail.chatCount) chats") }
                if let ph = detail.peakHour { chip("peak " + String(format: "%02d:00", ph)) }
            }
            tokenRows
            if !detail.models.isEmpty {
                tags("MODELS", detail.models) { model.modelColor($0, dark: dark) }
            }
            if detail.sources.count > 1 {
                tags("SOURCES", detail.sources) { model.sourceColor($0, dark: dark) }
            }
            if !detail.projects.isEmpty { projectList }
        }
        .padding(UIScale.pt(12))
        .frame(width: UIScale.pt(258))
        .background(DashSkin.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(.primary.opacity(0.1)))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(9), weight: .medium))
            .padding(.horizontal, UIScale.pt(6)).padding(.vertical, UIScale.pt(2))
            .background(.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var tokenRows: some View {
        VStack(spacing: UIScale.pt(2)) {
            row("Input", detail.input)
            row("Output", detail.output)
            row("Cache write", detail.cacheCreate)
            row("Cache read", detail.cacheRead)
        }
    }

    private func row(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label).settingsCaption()
            Spacer()
            Text(DashFmt.tokens(value)).font(.system(size: UIScale.pt(10))).monospacedDigit()
                .presenterBlur(blurTokens)
        }
    }

    private func tags(_ title: String, _ items: [NamedValue], color: @escaping (String) -> Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title).font(.system(size: UIScale.pt(8), weight: .semibold)).tracking(
                UIScale.pt(0.8)
            )
            .foregroundStyle(.tertiary)
            FlowTags(items: items, color: color, blurTokens: blurTokens)
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text("TOP PROJECTS").font(.system(size: UIScale.pt(8), weight: .semibold)).tracking(
                UIScale.pt(0.8)
            )
            .foregroundStyle(.tertiary)
            ForEach(detail.projects.prefix(4)) { p in
                HStack {
                    Text(p.name).font(.system(size: UIScale.pt(10))).lineLimit(1)
                        .presenterBlur(.agents)
                    Spacer()
                    Text(DashFmt.tokens(p.value)).font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(.secondary)
                        .presenterBlur(blurTokens)
                }
            }
            if detail.projects.count > 4 {
                Text("+\(detail.projects.count - 4) more").font(.system(size: UIScale.pt(9)))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct FlowTags: View {
    let items: [NamedValue]
    let color: (String) -> Color
    var blurTokens = false

    var body: some View {
        WrapHStack(spacing: UIScale.pt(4), lineSpacing: 4) {
            ForEach(items.prefix(6)) { item in
                HStack(spacing: UIScale.pt(3)) {
                    Circle().fill(color(item.id)).frame(width: UIScale.pt(6), height: UIScale.pt(6))
                    Text("\(item.name) \(DashFmt.tokens(item.value))")
                        .font(.system(size: UIScale.pt(9)))
                        .presenterBlur(blurTokens)
                }
                .padding(.horizontal, UIScale.pt(5)).padding(.vertical, UIScale.pt(2))
                .background(.primary.opacity(0.06), in: Capsule())
            }
        }
    }
}

struct WrapHStack<Content: View>: View {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        _WrapLayout(spacing: spacing, lineSpacing: lineSpacing) { content() }
    }
}

struct _WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize])
        -> CGSize
    {
        let maxWidth = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for size in cache {
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]
    ) {
        var y: CGFloat = bounds.minY
        var line: [(view: LayoutSubviews.Element, size: CGSize)] = []
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        func flushLine() {
            var x = bounds.minX
            for entry in line {
                entry.view.place(
                    at: CGPoint(x: x, y: y + (lineHeight - entry.size.height) / 2),
                    proposal: .unspecified)
                x += entry.size.width + spacing
            }
            y += lineHeight + lineSpacing
            line = []
            lineWidth = 0
            lineHeight = 0
        }

        for (index, view) in subviews.enumerated() {
            let size =
                cache.indices.contains(index) ? cache[index] : view.sizeThatFits(.unspecified)
            if lineWidth + size.width > bounds.width, !line.isEmpty {
                flushLine()
            }
            line.append((view, size))
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        flushLine()
    }
}

struct DashCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                eyebrow(title)
                if let subtitle {
                    Text(subtitle).font(.system(size: UIScale.pt(10))).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            content()
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetBar(cornerRadius: 14, fill: .primary.opacity(0.05))
    }
}
