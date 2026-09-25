import EdithKit
import SwiftUI

struct AttentionOverview: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    private var summary: AttentionSummary { model.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            AttentionHeadline(model: model)
            AttentionDayPanel(model: model)
            columns {
                AttentionCategoryPanel(model: model)
            } trailing: {
                AttentionHoursPanel(model: model)
            }
            AttentionEntitiesPanel(model: model, limit: 12)
            if !model.triage.isEmpty {
                AttentionTriagePanel(model: model)
            }
            columns {
                AttentionEdithPanel(model: model)
            } trailing: {
                AttentionSwitchingPanel(model: model)
            }
            columns {
                AttentionAgentsSummaryPanel(model: model)
            } trailing: {
                AttentionListeningPanel(model: model)
            }
        }
    }

    @ViewBuilder
    private func columns<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                leading()
                trailing()
            }
        } else {
            HStack(alignment: .top, spacing: UIScale.pt(14)) {
                leading().frame(maxWidth: .infinity, alignment: .top)
                trailing().frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

struct AttentionHeadline: View {
    let model: AttentionPageModel
    @Environment(\.compactLayout) private var compact
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let summary = model.summary
        let previous = summary.previous
        let dark = scheme == .dark
        let active = summary.activeDuration
        let productive = summary.duration(.focus)
        let distracting = summary.duration(.entertainment)
        let hours = max(active / 3_600, 1 / 60)
        let perHour = Double(summary.contextSwitches) / hours
        let longestBlock = summary.focusBlocks.map(\.duration).max() ?? 0
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: UIScale.pt(12)), count: compact ? 2 : 6),
            spacing: UIScale.pt(12)
        ) {
            AttentionTile(
                label: "Active", value: AttentionFormat.duration(active),
                detail: AttentionFormat.delta(active, previous?.active)
                    ?? "\(AttentionFormat.duration(summary.idleDuration)) away",
                tint: DashSkin.inkSoft(dark), symbol: "clock")
            AttentionTile(
                label: "Productive", value: AttentionFormat.duration(productive),
                detail:
                    "\(AttentionFormat.percent(productive, of: active)) · \(AttentionFormat.delta(productive, previous?.duration(.focus)) ?? "of active time")",
                tint: AttentionPalette.kind(.focus, dark: dark), symbol: "scope")
            AttentionTile(
                label: "Deep work", value: AttentionFormat.duration(summary.deepWorkDuration),
                detail: summary.focusBlocks.isEmpty
                    ? "no block of \(Int(model.settings.focusBlockMinimum / 60))m yet"
                    : "\(summary.focusBlocks.count) blocks, longest \(AttentionFormat.duration(longestBlock))",
                tint: AttentionPalette.kind(.focus, dark: dark), symbol: "brain.head.profile")
            AttentionTile(
                label: "Distracting", value: AttentionFormat.duration(distracting),
                detail:
                    "\(AttentionFormat.percent(distracting, of: active)) · \(AttentionFormat.delta(distracting, previous?.duration(.entertainment)) ?? "of active time")",
                tint: AttentionPalette.kind(.entertainment, dark: dark), symbol: "play.rectangle")
            AttentionTile(
                label: "Switches", value: String(format: "%.0f/h", perHour),
                detail:
                    "\(summary.contextSwitches) total · \(AttentionFormat.duration(summary.medianStretch)) median stretch",
                tint: DashPalette.color(dark ? "#d55181" : "#e87ba4"),
                symbol: "arrow.triangle.2.circlepath")
            AttentionTile(
                label: "Agent work", value: AttentionFormat.duration(summary.agents.working),
                detail: summary.agents.isEmpty
                    ? "no agent activity recorded"
                    : "peak \(summary.agents.peakConcurrent) at once · \(AttentionFormat.delta(summary.agents.working, previous?.agentWorking) ?? "")",
                tint: DashPalette.color(dark ? "#9085e9" : "#4a3aa7"), symbol: "sparkles")
        }
    }
}

struct AttentionDayPanel: View {
    let model: AttentionPageModel

    var body: some View {
        let summary = model.summary
        let interval = model.period.interval()
        let day = DateInterval(start: interval.start, duration: 86_400)
        let range = AttentionDayRibbon.visibleRange(
            summary.spans.flatMap { [$0.start, $0.end] }
                + summary.agents.concurrency.filter { $0.working > 0 }.map(\.start), day: day)
        AttentionPanel(
            model.period.scope == .day ? "Your day" : "Day by day",
            subtitle: model.period.scope == .day
                ? "Every stretch of attention, colored by kind. Hover to see what it was."
                : "Active time per day, split by kind."
        ) {
            if summary.activeDuration == 0 {
                AttentionEmpty(text: "No active time in this period", symbol: "moon.zzz")
            } else {
                if model.period.scope == .day {
                    AttentionDayRibbon(spans: summary.spans, settings: model.settings, day: day)
                } else {
                    AttentionDailyStack(days: summary.days, settings: model.settings)
                }
                AttentionKindLegend(kinds: summary.kinds, total: summary.activeDuration)
            }
            if model.period.scope == .day,
                summary.agents.concurrency.contains(where: { $0.working > 0 })
            {
                Divider()
                Text("Agents working")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                AttentionConcurrencyChart(
                    points: summary.agents.concurrency.filter { range.contains($0.start) },
                    domain: range, height: 70)
            }
        }
    }
}

struct AttentionCategoryPanel: View {
    let model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let summary = model.summary
        let dark = scheme == .dark
        AttentionPanel("Categories", subtitle: "Click a category to break it down.") {
            if summary.categories.isEmpty {
                AttentionEmpty(text: "Nothing categorized yet")
            } else {
                HStack(alignment: .center, spacing: UIScale.pt(16)) {
                    AttentionCategoryDonut(
                        categories: summary.categories, total: summary.activeDuration
                    )
                    .frame(width: UIScale.pt(150), height: UIScale.pt(150))
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        ForEach(summary.categories.prefix(8)) { item in
                            Button {
                                model.filter(category: item.category.id)
                            } label: {
                                AttentionLegendRow(
                                    color: AttentionPalette.category(item.category, dark: dark),
                                    label: item.category.name,
                                    value: AttentionFormat.duration(item.duration),
                                    detail: AttentionFormat.percent(
                                        item.duration, of: summary.activeDuration))
                            }
                            .buttonStyle(.edith(.borderless))
                        }
                        if summary.categories.count > 8 {
                            let rest = summary.categories.dropFirst(8).reduce(0) {
                                $0 + $1.duration
                            }
                            AttentionLegendRow(
                                color: DashSkin.grid(dark),
                                label: "\(summary.categories.count - 8) more",
                                value: AttentionFormat.duration(rest))
                        }
                    }
                }
            }
        }
    }
}

struct AttentionHoursPanel: View {
    let model: AttentionPageModel

    var body: some View {
        let summary = model.summary
        AttentionPanel(
            model.period.scope == .day ? "Hour by hour" : "When you work",
            subtitle: model.period.scope == .day
                ? "Active minutes in each hour, split by kind."
                : "Active time by weekday and hour. Darker is busier."
        ) {
            if summary.hours.isEmpty {
                AttentionEmpty(text: "No active hours yet", symbol: "clock")
            } else if model.period.scope == .day {
                AttentionHourBars(cells: summary.hours)
            } else {
                AttentionWeekHeatmap(cells: summary.hours)
            }
        }
    }
}

struct AttentionEntitiesPanel: View {
    @Bindable var model: AttentionPageModel
    let limit: Int
    @State private var expanded: Set<String> = []
    @State private var showAll = false

    var body: some View {
        let entities = model.summary.entities
        let shown = showAll ? Array(entities.prefix(80)) : Array(entities.prefix(limit))
        let top = entities.first?.duration ?? 1
        AttentionPanel(
            "Where time went",
            subtitle: "Apps and sites by active time. Recategorizing updates all history.",
            trailing: {
                if entities.count > limit {
                    Button(showAll ? "Show fewer" : "Show all \(min(entities.count, 80))") {
                        showAll.toggle()
                    }
                    .buttonStyle(.edith(.borderless))
                    .font(.system(size: UIScale.pt(11.5)))
                }
            }
        ) {
            if entities.isEmpty {
                AttentionEmpty(text: "No active apps or sites in this period")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entity in
                        if index > 0 { Divider().opacity(0.6) }
                        AttentionEntityRow(
                            model: model, entity: entity, scale: top,
                            total: model.summary.activeDuration,
                            expanded: expanded.contains(entity.id)
                        ) {
                            if expanded.contains(entity.id) {
                                expanded.remove(entity.id)
                            } else {
                                expanded.insert(entity.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct AttentionEntityRow: View {
    let model: AttentionPageModel
    let entity: AttentionEntity
    let scale: TimeInterval
    let total: TimeInterval
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            HStack(spacing: UIScale.pt(10)) {
                Button(action: toggle) {
                    HStack(spacing: UIScale.pt(10)) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIScale.pt(9), weight: .semibold))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(entity.details.isEmpty ? 0 : 1)
                        AttentionEntityIcon(entity: entity)
                        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                            HStack(spacing: UIScale.pt(6)) {
                                Text(entity.name)
                                    .font(.system(size: UIScale.pt(13), weight: .medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                AttentionCategoryBadge(
                                    category: entity.category, source: entity.categorySource,
                                    confidence: entity.confidence)
                            }
                            AttentionMixBar(
                                categories: entity.categoryDurations, total: entity.duration,
                                scale: scale, settings: model.settings)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel(
                    "\(entity.name), \(entity.category.name), \(AttentionFormat.duration(entity.duration))"
                )
                VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                    Text(AttentionFormat.duration(entity.duration))
                        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(
                        "\(AttentionFormat.percent(entity.duration, of: total)) · \(entity.visits) visits"
                    )
                    .font(.system(size: UIScale.pt(10)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
                .frame(minWidth: UIScale.pt(88), alignment: .trailing)
                AttentionCategoryMenu(model: model, entity: entity)
            }
            if expanded {
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    ForEach(entity.details) { detail in
                        HStack(spacing: UIScale.pt(8)) {
                            Circle()
                                .fill(
                                    AttentionPalette.category(
                                        model.category(detail.categoryID), dark: dark)
                                )
                                .frame(width: UIScale.pt(6), height: UIScale.pt(6))
                            Text(detail.name)
                                .font(.system(size: UIScale.pt(11.5)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                                .lineLimit(1)
                                .help(detail.url ?? detail.name)
                            Spacer(minLength: UIScale.pt(8))
                            Text(AttentionFormat.duration(detail.duration))
                                .font(.system(size: UIScale.pt(11)))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkFaint(dark))
                        }
                    }
                    if entity.signals.interactions > 0 {
                        Text(
                            "\(AttentionFormat.count(entity.signals.keys)) keys · \(AttentionFormat.count(entity.signals.clicks)) clicks · \(AttentionFormat.count(entity.signals.scrolls)) scrolls"
                        )
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                }
                .padding(.leading, UIScale.pt(58))
                .padding(.bottom, UIScale.pt(4))
            }
        }
        .padding(.vertical, UIScale.pt(7))
    }
}

struct AttentionCategoryMenu: View {
    let model: AttentionPageModel
    let entity: AttentionEntity

    var body: some View {
        Menu {
            ForEach(AttentionPalette.kinds, id: \.self) { kind in
                let categories = model.settings.categories.filter { $0.kind == kind }
                if !categories.isEmpty {
                    Section(kind.title) {
                        ForEach(categories) { category in
                            Button {
                                model.assign(entity: entity, to: category.id)
                            } label: {
                                if category.id == entity.category.id {
                                    Label(category.name, systemImage: "checkmark")
                                } else {
                                    Text(category.name)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "tag")
                .font(.system(size: UIScale.pt(12)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: UIScale.pt(24))
        .help("Change category")
    }
}

struct AttentionTriagePanel: View {
    let model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let items = Array(model.triage.prefix(10))
        let quick = Array(model.quickCategories.prefix(6))
        AttentionPanel(
            "Needs a category",
            subtitle:
                "Pick one and every past and future visit follows. Jev suggestions are marked with their confidence.",
            trailing: {
                Button {
                    model.categorizeNow()
                } label: {
                    HStack(spacing: UIScale.pt(5)) {
                        if model.categorizing { ProgressView().controlSize(.mini) }
                        Text(model.categorizing ? "Asking Jev" : "Ask Jev")
                    }
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.categorizing || !model.settings.jevCategorizationEnabled)
            }
        ) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, entity in
                    if index > 0 { Divider().opacity(0.6) }
                    HStack(spacing: UIScale.pt(10)) {
                        AttentionEntityIcon(entity: entity, size: 26)
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text(entity.name)
                                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                                .foregroundStyle(DashSkin.ink(dark))
                                .lineLimit(1)
                            Text(
                                entity.details.first?.name
                                    ?? AttentionFormat.duration(entity.duration)
                            )
                            .font(.system(size: UIScale.pt(10.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .lineLimit(1)
                        }
                        .frame(minWidth: UIScale.pt(140), alignment: .leading)
                        Text(AttentionFormat.duration(entity.duration))
                            .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(DashSkin.inkSoft(dark))
                        Spacer(minLength: UIScale.pt(6))
                        if entity.categorySource == .jev {
                            Button {
                                model.assign(entity: entity, to: entity.category.id)
                            } label: {
                                AttentionChip(
                                    title: "Keep \(entity.category.name)",
                                    color: AttentionPalette.category(entity.category, dark: dark),
                                    active: true)
                            }
                            .buttonStyle(.edith(.borderless))
                        }
                        ForEach(quick.filter { $0.id != entity.category.id }.prefix(4)) {
                            category in
                            Button {
                                model.assign(entity: entity, to: category.id)
                            } label: {
                                AttentionChip(
                                    title: category.name,
                                    color: AttentionPalette.category(category, dark: dark))
                            }
                            .buttonStyle(.edith(.borderless))
                        }
                        AttentionCategoryMenu(model: model, entity: entity)
                    }
                    .padding(.vertical, UIScale.pt(6))
                }
            }
        }
    }
}

struct AttentionRankRow: Identifiable {
    var id: String { label }
    var label: String
    var value: TimeInterval
    var detail: String?
    var color: Color
}

struct AttentionRankList: View {
    let rows: [AttentionRankRow]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let top = rows.map(\.value).max() ?? 1
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text(row.label)
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                        }
                        Spacer(minLength: UIScale.pt(6))
                        Text(AttentionFormat.duration(row.value))
                            .font(.system(size: UIScale.pt(11.5), weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(DashSkin.inkSoft(dark))
                    }
                    GeometryReader { geometry in
                        Capsule().fill(row.color)
                            .frame(width: max(2, geometry.size.width * row.value / max(top, 1)))
                    }
                    .frame(height: UIScale.pt(4))
                }
            }
        }
    }
}

struct AttentionEdithPanel: View {
    let model: AttentionPageModel
    @State private var dimension = AttentionTag.page
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let options = [
            AttentionTag.page, AttentionTag.machine, AttentionTag.agent, AttentionTag.project,
        ].filter { model.summary.dimension($0) != nil }
        let rows = (model.summary.dimension(dimension)?.rows ?? []).prefix(7).map { row in
            AttentionRankRow(
                label: dimension == AttentionTag.page
                    ? (MainDestination(rawValue: row.key)?.title ?? row.key) : row.key,
                value: row.duration, detail: nil,
                color: DashPalette.color(dark ? "#9085e9" : "#4a3aa7"))
        }
        AttentionPanel(
            "Inside Edith",
            subtitle: "Which pages, machines, agents and projects held your attention.",
            trailing: {
                if options.count > 1 {
                    Picker("Group", selection: $dimension) {
                        ForEach(options, id: \.self) { key in
                            Text(AttentionTag.title(key)).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        ) {
            if rows.isEmpty {
                AttentionEmpty(
                    text: "Time in Edith appears here with its page, machine and agent",
                    symbol: "rectangle.3.group")
            } else {
                AttentionRankList(rows: Array(rows))
            }
        }
    }
}

struct AttentionSwitchingPanel: View {
    let model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let summary = model.summary
        let dark = scheme == .dark
        AttentionPanel(
            "Attention span",
            subtitle:
                "Switches ignore visits under ten seconds, so flicking past a window is not counted."
        ) {
            HStack(spacing: UIScale.pt(18)) {
                stat("Median stretch", AttentionFormat.duration(summary.medianStretch), dark)
                stat("Longest", AttentionFormat.duration(summary.longestStretch), dark)
                stat("Switches", "\(summary.contextSwitches)", dark)
                if let previous = summary.previous {
                    stat("Before", "\(previous.contextSwitches)", dark)
                }
            }
            if summary.transitions.isEmpty {
                AttentionEmpty(text: "No switches yet", symbol: "arrow.left.arrow.right")
            } else {
                Text("Most common switches")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    ForEach(summary.transitions.prefix(6)) { transition in
                        HStack(spacing: UIScale.pt(6)) {
                            Text(transition.from).lineLimit(1)
                            Image(systemName: "arrow.right")
                                .font(.system(size: UIScale.pt(9)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(transition.to).lineLimit(1)
                            Spacer(minLength: UIScale.pt(6))
                            Text("\(transition.count)×")
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.ink(dark))
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(value)
                .font(DashSkin.heading(17))
                .monospacedDigit()
                .foregroundStyle(DashSkin.ink(dark))
            Text(label)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }
}

struct AttentionAgentsSummaryPanel: View {
    let model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let agents = model.summary.agents
        let dark = scheme == .dark
        AttentionPanel(
            "Agents",
            subtitle: "Time agents spent working on each machine, whether or not you watched.",
            trailing: {
                Button("Details") { model.section = .agents }
                    .buttonStyle(.edith(.borderless))
                    .font(.system(size: UIScale.pt(11.5)))
            }
        ) {
            if agents.isEmpty {
                AttentionEmpty(
                    text: model.settings.agentTrackingEnabled
                        ? "Agent work appears as Herdr sessions run"
                        : "Agent tracking is off in Attention settings",
                    symbol: "sparkles")
            } else {
                AttentionRankList(
                    rows: agents.machines.prefix(5).map {
                        AttentionRankRow(
                            label: $0.key, value: $0.working,
                            detail: "\($0.sessions) sessions",
                            color: DashPalette.color(dark ? "#9085e9" : "#4a3aa7"))
                    })
                HStack(spacing: UIScale.pt(6)) {
                    ForEach(agents.kinds.prefix(4)) { kind in
                        AttentionChip(
                            title: "\(kind.key) \(AttentionFormat.duration(kind.working))",
                            color: DashPalette.color(dark ? "#9085e9" : "#4a3aa7"))
                    }
                }
            }
        }
    }
}

struct AttentionListeningPanel: View {
    let model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let music = model.summary.music
        let dark = scheme == .dark
        AttentionPanel(
            "Listening",
            subtitle: "Edith's player, Spotify, Apple Music and background browser tabs."
        ) {
            if music.isEmpty {
                AttentionEmpty(text: "Nothing played in this period", symbol: "music.note")
            } else {
                VStack(spacing: UIScale.pt(7)) {
                    ForEach(music.prefix(6)) { item in
                        HStack(spacing: UIScale.pt(10)) {
                            Image(systemName: "music.note")
                                .foregroundStyle(DashPalette.color(dark ? "#d55181" : "#e87ba4"))
                                .frame(width: UIScale.pt(20))
                            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                                Text(item.title)
                                    .font(.system(size: UIScale.pt(12)))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Text(
                                    [item.artist, item.service].compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                            }
                            Spacer(minLength: UIScale.pt(6))
                            Text(AttentionFormat.duration(item.duration))
                                .font(.system(size: UIScale.pt(11.5)))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                    }
                }
            }
        }
    }
}
