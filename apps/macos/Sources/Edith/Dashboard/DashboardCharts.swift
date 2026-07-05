import Charts
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
    var scroll = false
    var height: CGFloat = 200
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
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Day", p.label))
                    .foregroundStyle(.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(
                        position: .top, alignment: .center, spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        PointTooltip(label: p.label, tokens: p.tokens, cost: p.cost)
                    }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.tokens(d)).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
            AxisMarks(position: .trailing) { value in
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.usd(d / scale)).font(.system(size: 8)).foregroundStyle(
                            lineColor)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel(orientation: .verticalReversed)
                    .font(.system(size: 7)).foregroundStyle(.tertiary)
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: height)
        .padding(.top, 22)

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
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(DashFmt.tokens(tokens)).font(.system(size: 11, weight: .semibold))
            Text(DashFmt.usdFull(cost)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)))
    }
}

struct StackDatum: Identifiable {
    let id: String
    let x: String
    let series: String
    let value: Double
}

struct StackedChart: View {
    let bars: [StackDatum]
    let costLine: [ComboPoint]
    let domain: [String]
    let range: [Color]
    var scroll = true
    var height: CGFloat = 200
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
                .foregroundStyle(.secondary)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Day", p.label))
                    .foregroundStyle(.primary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(
                        position: .top, alignment: .center, spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                    ) {
                        PointTooltip(label: p.label, tokens: p.tokens, cost: p.cost)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(DashFmt.tokens(d)).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel(orientation: .verticalReversed)
                    .font(.system(size: 7)).foregroundStyle(.tertiary)
            }
        }
        .chartLegend(position: .bottom, alignment: .center, spacing: 6)
        .frame(height: height)
        .padding(.top, 22)

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

struct DonutChart: View {
    let slices: [DonutSlice]
    var height: CGFloat = 220

    var body: some View {
        let total = max(slices.reduce(0) { $0 + $1.value }, 1)
        Chart(slices) { s in
            SectorMark(
                angle: .value("Tokens", s.value),
                innerRadius: .ratio(0.62),
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(by: .value("Model", s.label))
        }
        .chartForegroundStyleScale(
            domain: slices.map(\.label), range: slices.map(\.color)
        )
        .chartLegend(position: .bottom, alignment: .center, spacing: 6)
        .frame(height: height)
        .overlay {
            VStack(spacing: 1) {
                Text(DashFmt.tokens(total)).font(.system(size: 13, weight: .semibold))
                Text("tokens").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .offset(y: -14)
        }
    }
}

struct HeatCard: View {
    let detail: HeatDay
    let model: DashboardModel
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardModel.ymd.string(from: detail.date))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(DashFmt.tokens(detail.tokens)) tokens · \(DashFmt.usdFull(detail.cost))")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 5) {
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
        .padding(12)
        .frame(width: 258)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var tokenRows: some View {
        VStack(spacing: 2) {
            row("Input", detail.input)
            row("Output", detail.output)
            row("Cache write", detail.cacheCreate)
            row("Cache read", detail.cacheRead)
        }
    }

    private func row(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(DashFmt.tokens(value)).font(.system(size: 10)).monospacedDigit()
        }
    }

    private func tags(_ title: String, _ items: [NamedValue], color: @escaping (String) -> Color)
        -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.tertiary)
            FlowTags(items: items, color: color)
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOP PROJECTS").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(.tertiary)
            ForEach(detail.projects.prefix(4)) { p in
                HStack {
                    Text(p.name).font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text(DashFmt.tokens(p.value)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if detail.projects.count > 4 {
                Text("+\(detail.projects.count - 4) more").font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct FlowTags: View {
    let items: [NamedValue]
    let color: (String) -> Color

    var body: some View {
        WrapHStack(spacing: 4, lineSpacing: 4) {
            ForEach(items.prefix(6)) { item in
                HStack(spacing: 3) {
                    Circle().fill(color(item.id)).frame(width: 6, height: 6)
                    Text("\(item.name) \(DashFmt.tokens(item.value))")
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 5).padding(.vertical, 2)
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
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
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct TerminalLogView: View {
    let log: String
    let theme: Color
    var height: CGFloat = 140

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "No output yet — hit reload" : log)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .onChange(of: log) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(height: height)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct DashCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                eyebrow(title)
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}
