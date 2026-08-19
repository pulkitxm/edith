import Charts
import EdithKit
import SwiftUI

struct ComboPoint: Identifiable {
    let id: String
    let label: String
    let tokens: Double
    let cost: Double
}

private func costScale(_ points: [ComboPoint]) -> Double {
    let maxTok = max(points.map(\.tokens).max() ?? 0, 1)
    let maxCost = max(points.map(\.cost).max() ?? 0, 0.0001)
    return maxTok / maxCost
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
    @State private var selected: String?

    private var selectedPoint: ComboPoint? {
        selected.flatMap { sel in points.first { $0.label == sel } }
    }

    var body: some View {
        let scale = costScale(points)
        let chart = Chart {
            ForEach(points) { p in
                BarMark(
                    x: .value("Day", p.label),
                    y: .value("Tokens", p.tokens)
                )
                .foregroundStyle(
                    barColor.opacity(selected == nil || selected == p.label ? 0.7 : 0.28)
                )
                .cornerRadius(2)
            }
            ForEach(points) { p in
                LineMark(
                    x: .value("Day", p.label),
                    y: .value("Cost", p.cost * scale)
                )
                .foregroundStyle(lineColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1.5)))
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Day", p.label))
                    .foregroundStyle(DashSkin.lineStrong(dark))
                    .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [3, 3]))
                    .annotation(
                        position: .top, alignment: .center, spacing: UIScale.pt(6),
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        PointTooltip(
                            label: p.label, tokens: p.tokens, cost: p.cost, dark: dark, blur: blur,
                            blurTokens: blurTokens)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(DashSkin.line(dark))
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
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel(orientation: .verticalReversed)
                    .font(.system(size: UIScale.pt(10.5))).foregroundStyle(DashSkin.ink(dark))
            }
        }
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

struct PointTooltip: View {
    let label: String
    let tokens: Double
    let cost: Double
    var dark = false
    var blur = false
    var blurTokens = false
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(1)) {
            Text(label).font(.system(size: UIScale.pt(9))).foregroundStyle(DashSkin.inkFaint(dark))
            Text(DashFmt.tokens(tokens)).font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(DashSkin.ink(dark))
                .presenterBlur(blurTokens)
            Text(DashFmt.usdFull(cost)).font(.system(size: UIScale.pt(10))).foregroundStyle(
                DashSkin.inkFaint(dark)
            )
            .presenterBlur(blur)
        }
        .padding(.horizontal, UIScale.pt(8)).padding(.vertical, UIScale.pt(5))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(7)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(7)).strokeBorder(DashSkin.line(dark)))
    }
}

struct StackDatum: Identifiable {
    let id: String
    let x: String
    let series: String
    let value: Double
}

struct DashChartData {
    var daily: [ComboPoint] = []
    var dow: [ComboPoint] = []
    var hourly: [ComboPoint] = []
    var project: [ComboPoint] = []
    var tokenMix: [StackDatum] = []
    var modelTime: [StackDatum] = []
    var source: [StackDatum] = []
    var heatCuts: [Double] = [0, 0, 0]
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
    @State private var selected: String?

    private var selectedPoint: ComboPoint? {
        selected.flatMap { sel in costLine.first { $0.label == sel } }
    }

    var body: some View {
        let scale = costScale(costLine)
        let chart = Chart {
            ForEach(bars) { d in
                BarMark(
                    x: .value("Day", d.x),
                    y: .value("Tokens", d.value)
                )
                .foregroundStyle(by: .value("Series", d.series))
                .opacity(selected == nil || selected == d.x ? 1 : 0.35)
            }
            ForEach(costLine) { p in
                LineMark(
                    x: .value("Day", p.label),
                    y: .value("Cost", p.cost * scale)
                )
                .foregroundStyle(DashSkin.inkSoft(dark))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1.2)))
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Day", p.label))
                    .foregroundStyle(DashSkin.lineStrong(dark))
                    .lineStyle(StrokeStyle(lineWidth: UIScale.pt(1), dash: [3, 3]))
                    .annotation(
                        position: .top, alignment: .center, spacing: UIScale.pt(6),
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        PointTooltip(
                            label: p.label, tokens: p.tokens, cost: p.cost, dark: dark, blur: blur,
                            blurTokens: blurTokens)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(DashSkin.line(dark))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.tokens(d)).font(.system(size: UIScale.pt(9))).foregroundStyle(
                            DashSkin.inkSoft(dark)
                        ).presenterBlur(blurTokens)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel(orientation: .verticalReversed)
                    .font(.system(size: UIScale.pt(10.5))).foregroundStyle(DashSkin.ink(dark))
            }
        }
        .chartLegend(position: .bottom, alignment: .center, spacing: UIScale.pt(6))
        .frame(height: height)
        .padding(.top, UIScale.pt(22))

        if scroll, costLine.count > 30 {
            chart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 30)
        } else {
            chart
        }
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

struct DonutChart: View {
    let slices: [DonutSlice]
    var dark = false
    var height: CGFloat = 220
    var blurTokens = false
    @State private var angle: Double?

    private var selected: DonutSlice? {
        angle.flatMap { donutSlice(at: $0, in: slices) }
    }

    var body: some View {
        let total = donutTotal(slices)
        let percentageTotal = max(total, 1)
        Chart(slices) { s in
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
        .chartLegend(position: .bottom, alignment: .center, spacing: UIScale.pt(6))
        .frame(height: height)
        .overlay {
            VStack(spacing: UIScale.pt(1)) {
                if let s = selected {
                    Text(s.label)
                        .font(.system(size: UIScale.pt(10), weight: .medium)).foregroundStyle(
                            DashSkin.inkSoft(dark)
                        )
                        .lineLimit(1)
                    Text(DashFmt.tokens(s.value)).font(
                        .system(size: UIScale.pt(13), weight: .semibold)
                    )
                    .foregroundStyle(DashSkin.ink(dark))
                    .presenterBlur(blurTokens)
                    Text(DashFmt.pct(s.value / percentageTotal)).font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                } else {
                    Text(DashFmt.tokens(total)).font(
                        .system(size: UIScale.pt(13), weight: .semibold)
                    )
                    .foregroundStyle(DashSkin.ink(dark))
                    .presenterBlur(blurTokens)
                    Text("tokens").font(.system(size: UIScale.pt(8))).foregroundStyle(
                        DashSkin.inkFaint(dark))
                }
            }
            .frame(maxWidth: UIScale.pt(110))
            .offset(y: -14)
            .allowsHitTesting(false)
        }
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
                .font(.system(size: UIScale.pt(11), weight: .semibold)).foregroundStyle(
                    DashSkin.inkSoft(dark))
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
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark)))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: UIScale.pt(9), weight: .medium))
            .padding(.horizontal, UIScale.pt(6)).padding(.vertical, UIScale.pt(2))
            .background(DashSkin.line(dark), in: Capsule())
            .foregroundStyle(DashSkin.inkSoft(dark))
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
            .foregroundStyle(DashSkin.inkFaint(dark))
            FlowTags(items: items, color: color, dark: dark, blurTokens: blurTokens)
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text("TOP PROJECTS").font(.system(size: UIScale.pt(8), weight: .semibold)).tracking(
                UIScale.pt(0.8)
            )
            .foregroundStyle(DashSkin.inkFaint(dark))
            ForEach(detail.projects.prefix(4)) { p in
                HStack {
                    Text(p.name).font(.system(size: UIScale.pt(10))).lineLimit(1)
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer()
                    Text(DashFmt.tokens(p.value)).font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .presenterBlur(blurTokens)
                }
            }
            if detail.projects.count > 4 {
                Text("+\(detail.projects.count - 4) more").font(.system(size: UIScale.pt(9)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }
}

struct FlowTags: View {
    let items: [NamedValue]
    let color: (String) -> Color
    var dark = false
    var blurTokens = false

    var body: some View {
        WrapHStack(spacing: UIScale.pt(4), lineSpacing: 4) {
            ForEach(items.prefix(6)) { item in
                HStack(spacing: UIScale.pt(3)) {
                    Circle().fill(color(item.id)).frame(width: UIScale.pt(6), height: UIScale.pt(6))
                    Text("\(item.name) \(DashFmt.tokens(item.value))")
                        .font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .presenterBlur(blurTokens)
                }
                .padding(.horizontal, UIScale.pt(5)).padding(.vertical, UIScale.pt(2))
                .background(DashSkin.line(dark), in: Capsule())
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
