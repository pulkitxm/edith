import EdithKit
import SwiftUI

struct AttentionTimelineBlock: Identifiable, Equatable {
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
        let dark = scheme == .dark
        HStack(spacing: UIScale.pt(6)) {
            ForEach(AttentionPalette.levels, id: \.self) { level in
                Button {
                    model.toggle(level: level)
                } label: {
                    AttentionChip(
                        title: level.title, color: AttentionPalette.level(level, dark: dark),
                        active: model.levelFilter == level)
                }
                .buttonStyle(.edith(.borderless))
            }
            ForEach([AttentionSphere.work, .personal], id: \.self) { sphere in
                Button {
                    model.toggle(sphere: sphere)
                } label: {
                    AttentionChip(
                        title: sphere.title, color: DashSkin.inkFaint(dark),
                        active: model.sphereFilter == sphere)
                }
                .buttonStyle(.edith(.borderless))
            }
            Menu {
                Button("All categories") { model.categoryFilter = nil }
                ForEach(model.settings.categories) { category in
                    Button(category.name) { model.filter(category: category.id, navigate: false) }
                }
            } label: {
                AttentionChip(
                    title: model.categoryFilter.map { model.category($0).name } ?? "Category",
                    color: model.categoryFilter.map {
                        AttentionPalette.category(model.category($0), dark: dark)
                    } ?? DashSkin.inkFaint(dark),
                    active: model.categoryFilter != nil)
            }
            .menuStyle(.button)
            .buttonStyle(.edith(.borderless))
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: UIScale.pt(8))
            if showsSearch {
                TextField("Search names and titles", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: UIScale.pt(240))
            }
            if model.hasFilters {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.edith(.borderless))
            }
        }
    }
}

struct AttentionTimelineView: View {
    @Bindable var model: AttentionPageModel

    var body: some View {
        let summary = model.summary
        let calendar = Calendar.current
        let days = Dictionary(grouping: summary.spans) { calendar.startOfDay(for: $0.start) }
            .sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            AttentionFilterBar(model: model)
            if model.period.scope == .month {
                AttentionPanel("Timeline") {
                    AttentionEmpty(
                        text:
                            "The timeline shows a day or a week at a time. Switch to Day or Week above.",
                        symbol: "calendar")
                }
            } else if days.isEmpty {
                AttentionPanel("Timeline") {
                    AttentionEmpty(text: "No activity in this period", symbol: "moon.zzz")
                }
            } else {
                ForEach(days, id: \.key) { day, spans in
                    AttentionTimelineDay(model: model, day: day, spans: spans)
                }
            }
        }
    }
}

private struct AttentionTimelineDay: View {
    let model: AttentionPageModel
    let day: Date
    let spans: [AttentionSpan]
    @State private var limit = 40
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let filtered = spans.filter { span in
            model.matches(span) && model.matchesSearch([span.name, span.detail])
        }
        let blocks = Array(AttentionTimelineBlock.blocks(filtered).reversed())
        let active = spans.reduce(0) { $0 + $1.duration }
        AttentionPanel(
            day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
            subtitle: "\(AttentionFormat.duration(active)) observed · \(blocks.count) blocks"
        ) {
            AttentionDayRibbon(
                spans: filtered, settings: model.settings,
                day: DateInterval(start: day, duration: 86_400), height: 38)
            if blocks.isEmpty {
                AttentionEmpty(text: "Nothing matches the filters on this day")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(blocks.prefix(limit).enumerated()), id: \.element.id) {
                        index, block in
                        if index > 0 { Divider().opacity(0.5) }
                        AttentionTimelineRow(model: model, block: block, dark: dark)
                    }
                }
                if blocks.count > limit {
                    Button("Show \(min(40, blocks.count - limit)) more") { limit += 40 }
                        .buttonStyle(.edith(.secondary))
                        .frame(maxWidth: .infinity)
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
