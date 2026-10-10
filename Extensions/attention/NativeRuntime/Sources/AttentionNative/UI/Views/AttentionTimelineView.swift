@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
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
        LazyVStack(alignment: .leading, spacing: UIScale.pt(14)) {
            AttentionFilterBar(model: model)
            if !model.period.showsSpans {
                AttentionPanel("Timeline") {
                    AttentionEmpty(
                        text:
                            "The timeline shows up to eight days at a time. Pick a shorter range above.",
                        symbol: "calendar")
                }
            } else if model.timeline.isEmpty {
                AttentionPanel("Timeline") {
                    AttentionEmpty(text: "No activity in this period", symbol: "moon.zzz")
                }
            } else {
                ForEach(model.timeline) { day in
                    AttentionTimelineDayPanel(model: model, day: day)
                }
            }
        }
    }
}

private struct AttentionTimelineDayPanel: View {
    let model: AttentionPageModel
    let day: AttentionTimelineDay
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        AttentionPanel(
            day.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
            subtitle:
                "\(AttentionFormat.duration(day.active)) observed · \(day.blocks.count) blocks"
        ) {
            AttentionDayRibbon(
                blocks: day.ribbon, day: DateInterval(start: day.day, duration: 86_400),
                height: 38)
            if day.blocks.isEmpty {
                AttentionEmpty(text: "Nothing matches the filters on this day")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(day.blocks.enumerated()), id: \.element.id) {
                        index, block in
                        if index > 0 { Divider().opacity(0.5) }
                        AttentionTimelineRow(model: model, block: block, dark: dark)
                    }
                }
            }
        }
    }
}

private struct AttentionTimelineRow: View {
    let model: AttentionPageModel
    let block: AttentionTimelineBlock
    let dark: Bool

    var body: some View {
        let category = model.category(block.categoryID)
        let context = [
            block.tags[AttentionTag.machine], block.tags[AttentionTag.agent],
            block.tags[AttentionTag.project], block.tags[AttentionTag.repository],
            block.tags[AttentionTag.channel],
        ].compactMap { $0 }
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                Text(AttentionFormat.time(block.start))
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.ink(dark))
                Text(AttentionFormat.time(block.end))
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
                        category: category, productivity: block.productivity, sphere: block.sphere)
                }
                if let detail = block.detail, detail != block.name {
                    Text(detail)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                }
                if !context.isEmpty || block.skipped > 0 {
                    Text(
                        (context
                            + (block.skipped > 0 ? ["after \(block.skipped) brief switches"] : []))
                            .joined(separator: " · ")
                    )
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
                }
            }
            Spacer(minLength: UIScale.pt(8))
            VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                Text(AttentionFormat.duration(block.duration))
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.ink(dark))
                if block.interactions > 0 {
                    Text("\(AttentionFormat.count(block.interactions)) inputs")
                        .font(.system(size: UIScale.pt(10)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
        .padding(.vertical, UIScale.pt(7))
    }
}
