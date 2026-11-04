internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import SwiftUI

struct AttentionTimelineBlock: Identifiable, Equatable, Sendable {
    var id: Date { start }
    var start: Date
    var end: Date
    var entityID: String
    var name: String
    var categoryID: String
    var details: [String: TimeInterval]
    var interactions: Int
    var tags: [String: String]
    var skipped: Int
    var productivity: AttentionProductivity
    var sphere: AttentionSphere

    var duration: TimeInterval { end.timeIntervalSince(start) }

    var detail: String? { details.max { $0.value < $1.value }?.key }

    static func blocks(
        _ spans: [AttentionSpan], gap: TimeInterval = 120, minimum: TimeInterval = 45
    )
        -> [AttentionTimelineBlock]
    {
        var blocks: [AttentionTimelineBlock] = []
        var skipped = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if var last = blocks.last, last.entityID == span.entityID,
                span.start.timeIntervalSince(last.end) <= gap
            {
                last.end = max(last.end, span.end)
                if let detail = span.detail { last.details[detail, default: 0] += span.duration }
                last.interactions += span.interactions
                blocks[blocks.count - 1] = last
                continue
            }
            if let last = blocks.last, last.duration < minimum {
                blocks.removeLast()
                skipped += 1
            }
            var details: [String: TimeInterval] = [:]
            if let detail = span.detail { details[detail] = span.duration }
            blocks.append(
                AttentionTimelineBlock(
                    start: span.start, end: span.end, entityID: span.entityID, name: span.name,
                    categoryID: span.categoryID, details: details,
                    interactions: span.interactions, tags: span.tags ?? [:], skipped: skipped,
                    productivity: span.productivity, sphere: span.sphere))
            skipped = 0
        }
        if let last = blocks.last, last.duration < minimum { blocks.removeLast() }
        return blocks
    }
}

struct AttentionFilterBar: View {
    @Bindable var model: AttentionPageModel
    var showsSearch = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filterMenu; search; reset
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    filterMenu; Spacer(); reset
                }
                search
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button("All activity") { model.clearFilters() }
            Section("Productivity") {
                ForEach(AttentionPalette.levels, id: \.self) { level in
                    Button(level.title) { model.toggle(level: level) }
                }
            }
            Section("Context") {
                ForEach(AttentionSphere.allCases, id: \.self) { sphere in
                    Button(sphere.title) { model.toggle(sphere: sphere) }
                }
            }
            Menu("Category") {
                ForEach(model.settings.categories) { category in
                    Button(category.name) { model.filter(category: category.id, navigate: false) }
                }
            }
        } label: {
            Label(
                model.categoryFilter.map { model.category($0).name }
                    ?? model.levelFilter?.title ?? model.sphereFilter?.title ?? "All activity",
                systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.button).buttonStyle(.edith(.secondary)).fixedSize()
    }

    @ViewBuilder private var search: some View {
        if showsSearch {
            SearchField(placeholder: "Search names and titles", text: $model.searchText)
                .frame(maxWidth: UIScale.pt(360))
        } else {
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var reset: some View {
        if model.hasFilters {
            Button("Clear filters") { model.clearFilters() }
                .buttonStyle(.edith(.borderless)).fixedSize()
        }
    }

}

struct AttentionTimelineView: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        if !model.period.showsSpans {
            AttentionPanel("Timeline") {
                AttentionEmpty(
                    text:
                        "The timeline shows up to eight days at a time. Pick a shorter range above.",
                    symbol: "calendar")
            }
        } else {
            AttentionPanel("Timeline") {
                AttentionEmpty(text: "No activity in this period", symbol: "moon.zzz")
            }
        }
    }
}

enum AttentionTimelineMetrics {
    static let cardPadding = 16.0
    static let ribbonHeight = 38.0
    static let ribbonTooltipInset = 42.0
    static let cardSpacing = 14.0
    static let cornerRadius = 14.0

    static func height(of row: AttentionTimelineRow) -> CGFloat {
        switch row.kind {
        case .day:
            scaled(
                cardPadding + 34 + PageMetrics.cardSpacing + ribbonTooltipInset + ribbonHeight
                    + PageMetrics.cardSpacing)
        case .empty:
            scaled(96)
        case .block(let entry):
            scaled(entryHeight(entry))
        case .end(let last):
            scaled(cardPadding + (last ? PageMetrics.bottom : cardSpacing))
        }
    }

    private static func entryHeight(_ entry: AttentionTimelineRow.Entry) -> Double {
        var lines = 18.0
        if entry.detail != nil { lines += 3 + 14 }
        if entry.context != nil { lines += 3 + 13 }
        return max(lines, 28) + 14
    }

    private static func scaled(_ points: Double) -> CGFloat {
        CGFloat(UIScale.pt(points).rounded())
    }
}

struct AttentionTimelineList<Header: View>: View {
    let model: AttentionPageModel
    @ViewBuilder let header: () -> Header

    var body: some View {
        VirtualList(
            model.timelineRows, rowHeight: AttentionTimelineMetrics.height, header: header
        ) { row in
            AttentionTimelineRowView(model: model, row: row).id(row.id)
        }
    }
}

private enum AttentionCardPosition {
    case top
    case middle
    case bottom
}

private struct AttentionCardSlice: View {
    let position: AttentionCardPosition
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        let radius = UIScale.pt(AttentionTimelineMetrics.cornerRadius)
        let top = position == .top ? radius : 0
        let bottom = position == .bottom ? radius : 0
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                topTrailingRadius: top, style: .continuous
            )
            .fill(DashSkin.paper2(dark))
            AttentionCardEdge(top: top, bottom: bottom)
                .stroke(
                    contrast == .increased ? DashSkin.lineStrong(dark) : DashSkin.line(dark),
                    lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .allowsHitTesting(false)
    }
}

private struct AttentionCardEdge: Shape {
    let top: CGFloat
    let bottom: CGFloat

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: 0.25, dy: 0)
        var path = Path()
        path.move(to: CGPoint(x: frame.minX, y: frame.maxY - bottom))
        path.addLine(to: CGPoint(x: frame.minX, y: frame.minY + top))
        if top > 0 {
            path.addQuadCurve(
                to: CGPoint(x: frame.minX + top, y: frame.minY + 0.25),
                control: CGPoint(x: frame.minX, y: frame.minY + 0.25))
            path.addLine(to: CGPoint(x: frame.maxX - top, y: frame.minY + 0.25))
            path.addQuadCurve(
                to: CGPoint(x: frame.maxX, y: frame.minY + top),
                control: CGPoint(x: frame.maxX, y: frame.minY + 0.25))
        } else {
            path.move(to: CGPoint(x: frame.maxX, y: frame.minY))
        }
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - bottom))
        if bottom > 0 {
            path.addQuadCurve(
                to: CGPoint(x: frame.maxX - bottom, y: frame.maxY - 0.25),
                control: CGPoint(x: frame.maxX, y: frame.maxY - 0.25))
            path.addLine(to: CGPoint(x: frame.minX + bottom, y: frame.maxY - 0.25))
            path.addQuadCurve(
                to: CGPoint(x: frame.minX, y: frame.maxY - bottom),
                control: CGPoint(x: frame.minX, y: frame.maxY - 0.25))
        }
        return path
    }
}

private struct AttentionTimelineRowView: View {
    let model: AttentionPageModel
    let row: AttentionTimelineRow
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let gutter = PageMetrics.gutter(compact)
        let height = AttentionTimelineMetrics.height(of: row)
        switch row.kind {
        case .day(let header):
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(header.title).font(.edithText(.headline))
                    Text(header.subtitle).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
                AttentionDayRibbon(
                    blocks: header.ribbon, day: header.interval,
                    height: AttentionTimelineMetrics.ribbonHeight)
            }
            .padding(.top, UIScale.pt(AttentionTimelineMetrics.cardPadding))
            .padding(.horizontal, UIScale.pt(AttentionTimelineMetrics.cardPadding))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background { AttentionCardSlice(position: .top) }
            .padding(.horizontal, gutter)
        case .empty:
            AttentionEmpty(text: "Nothing matches the filters on this day")
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background { AttentionCardSlice(position: .middle) }
                .padding(.horizontal, gutter)
        case .block(let entry):
            AttentionTimelineEntryView(model: model, entry: entry, dark: dark)
                .padding(.horizontal, UIScale.pt(AttentionTimelineMetrics.cardPadding))
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
                .overlay(alignment: .top) {
                    if !entry.first {
                        Divider().opacity(0.5)
                            .padding(.horizontal, UIScale.pt(AttentionTimelineMetrics.cardPadding))
                    }
                }
                .background { AttentionCardSlice(position: .middle) }
                .padding(.horizontal, gutter)
        case .end:
            Color.clear
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(alignment: .top) {
                    AttentionCardSlice(position: .bottom)
                        .frame(height: UIScale.pt(AttentionTimelineMetrics.cardPadding))
                }
                .padding(.horizontal, gutter)
        }
    }
}

private struct AttentionTimelineEntryView: View {
    let model: AttentionPageModel
    let entry: AttentionTimelineRow.Entry
    let dark: Bool

    var body: some View {
        let block = entry.block
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                Text(entry.start)
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.ink(dark))
                Text(entry.end)
                    .font(.system(size: UIScale.pt(10)))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .frame(width: UIScale.pt(64), alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(AttentionPalette.level(block.productivity, dark: dark))
                .frame(width: UIScale.pt(3))
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack(spacing: UIScale.pt(6)) {
                    Text(block.name)
                        .font(.system(size: UIScale.pt(12.5), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                        .lineLimit(1)
                    AttentionCategoryBadge(
                        category: model.category(block.categoryID),
                        productivity: block.productivity, sphere: block.sphere)
                }
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                }
                if let context = entry.context {
                    Text(context)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: UIScale.pt(8))
            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                Text(entry.duration)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.ink(dark))
                if let inputs = entry.inputs {
                    Text(inputs)
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
        .padding(.top, UIScale.pt(7))
    }
}
