@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import SwiftUI

struct AttentionOverview: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    private var summary: AttentionSummary { model.summary }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text(
                "App breakdowns and productivity show active use. Idle and locked time are kept separately."
            )
            .font(.edithText(.caption))
            .foregroundStyle(.secondary)
            AttentionHeadline(model: model)
            AttentionAllocationPanel(model: model)
            AttentionEntitiesPanel(model: model, limit: 12)
            AttentionDayPanel(model: model)
            columns {
                AttentionCategoryPanel(model: model)
            } trailing: {
                AttentionHoursPanel(model: model)
            }
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
        let accent = AttentionPalette.accent(dark)
        let quiet = DashSkin.inkSoft(dark)
        let active = summary.activeDuration
        let productive = summary.productiveDuration
        let distracting = summary.distractingDuration
        let hours = max(active / 3_600, 1 / 60)
        let perHour = Double(summary.contextSwitches) / hours
        let longestBlock = summary.focusBlocks.map(\.duration).max() ?? 0
        LazyVGrid(
            columns: PageMetrics.cardColumns(compact, minimum: 200, spacing: 12),
            spacing: UIScale.pt(12)
        ) {
            AttentionTile(
                label: "Screen time",
                value: AttentionFormat.duration(
                    summary.screenTime(excludingIdle: model.excludeIdleTime)),
                detail:
                    model.excludeIdleTime
                    ? "idle and locked time excluded" : "includes idle and locked time",
                tint: quiet, symbol: "clock")
            AttentionTile(
                label: "Idle / locked", value: AttentionFormat.duration(summary.idleDuration),
                detail: "idle after \(Int(model.settings.idleThreshold / 60))m without input",
                tint: quiet, symbol: "moon.zzz")
            AttentionTile(
                label: "Active", value: AttentionFormat.duration(active),
                detail:
                    "\(AttentionFormat.duration(summary.duration(AttentionSphere.work))) work · \(AttentionFormat.duration(summary.duration(AttentionSphere.personal))) personal",
                tint: quiet, symbol: "cursorarrow")
            AttentionTile(
                label: "Productive", value: AttentionFormat.duration(productive),
                detail:
                    "\(AttentionFormat.percent(productive, of: active)) · \(AttentionFormat.delta(productive, previous?.productive) ?? "of active time")",
                tint: accent, symbol: "scope")
            AttentionTile(
                label: "Distracting", value: AttentionFormat.duration(distracting),
                detail:
                    "\(AttentionFormat.percent(distracting, of: active)) · \(AttentionFormat.delta(distracting, previous?.distracting) ?? "of active time")",
                tint: AttentionPalette.level(.veryDistracting, dark: dark),
                symbol: "arrow.down.right")
            AttentionTile(
                label: "Deep work", value: AttentionFormat.duration(summary.deepWorkDuration),
                detail: summary.focusBlocks.isEmpty
                    ? "no block of \(Int(model.settings.focusBlockMinimum / 60))m yet"
                    : "\(summary.focusBlocks.count) blocks, longest \(AttentionFormat.duration(longestBlock))",
                tint: quiet, symbol: "brain.head.profile")
            AttentionTile(
                label: "Switches", value: String(format: "%.0f/h", perHour),
                detail:
                    "\(summary.contextSwitches) total · \(AttentionFormat.duration(summary.medianStretch)) median stretch",
                tint: quiet, symbol: "arrow.triangle.2.circlepath")
            AttentionTile(
                label: "Agent work", value: AttentionFormat.duration(summary.agents.working),
                detail: summary.agents.isEmpty
                    ? "no agent activity recorded"
                    : "peak \(summary.agents.peakConcurrent) at once · \(AttentionFormat.delta(summary.agents.working, previous?.agentWorking) ?? "")",
                tint: quiet, symbol: "sparkles")
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
            model.dayRibbon.flatMap { [$0.start, $0.end] }
                + summary.agents.concurrency.filter { $0.working > 0 }.map(\.start), day: day)
        AttentionPanel(
            model.period.isSingleDay ? "Your day" : "Day by day",
            subtitle: model.period.isSingleDay
                ? "Every stretch of attention, shaded by how productive it was. Hover to see what it was."
                : "Active time per day, split by productivity."
        ) {
            if summary.activeDuration == 0 {
                AttentionEmpty(text: "No active time in this period", symbol: "moon.zzz")
            } else {
                if model.period.isSingleDay {
                    AttentionDayRibbon(blocks: model.dayRibbon, day: day)
                } else {
                    AttentionDailyStack(days: summary.days, settings: model.settings)
                }
                AttentionLevelLegend(levels: summary.levels, total: summary.activeDuration)
            }
            if model.period.isSingleDay,
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

    var body: some View {
        let summary = model.summary
        AttentionPanel(
            "Categories",
            subtitle: "What the time was spent on. Click one to break it down."
        ) {
            if summary.categories.isEmpty {
                AttentionEmpty(text: "Nothing categorized yet")
            } else {
                AttentionCategoryBars(
                    categories: summary.categories, total: summary.activeDuration
                ) { model.filter(category: $0) }
            }
        }
    }
}

struct AttentionHoursPanel: View {
    let model: AttentionPageModel

    var body: some View {
        let summary = model.summary
        AttentionPanel(
            model.period.isSingleDay ? "Hour by hour" : "When you work",
            subtitle: model.period.isSingleDay
                ? "Active minutes in each hour, split by productivity."
                : "Active time by weekday and hour. Darker is busier."
        ) {
            if summary.hours.isEmpty {
                AttentionEmpty(text: "No active hours yet", symbol: "clock")
            } else if model.period.isSingleDay {
                AttentionHourBars(cells: summary.hours)
            } else {
                AttentionWeekHeatmap(cells: summary.hours)
            }
        }
    }
}

struct AttentionCategoryMenu: View {
    let model: AttentionPageModel
    let entity: AttentionEntity

    var body: some View {
        Menu {
            Menu("Category") {
                ForEach(AttentionPalette.levels, id: \.self) { level in
                    let categories = model.settings.categories.filter {
                        $0.productivity == level && !$0.isUnclassified
                    }
                    if !categories.isEmpty {
                        Section(level.title) {
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
            }
            Section("Productivity for you") {
                ForEach(AttentionPalette.levels, id: \.self) { level in
                    Button {
                        model.assign(entity: entity, productivity: level)
                    } label: {
                        if level == entity.productivity {
                            Label(level.title, systemImage: "checkmark")
                        } else {
                            Text(level.title)
                        }
                    }
                }
            }
            Section("Part of") {
                ForEach(AttentionSphere.allCases, id: \.self) { sphere in
                    Button {
                        model.assign(entity: entity, sphere: sphere)
                    } label: {
                        if sphere == entity.sphere {
                            Label(sphere.title, systemImage: "checkmark")
                        } else {
                            Text(sphere.title)
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
        .help("Change category, productivity or whether it is work or personal")
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
                    Text(model.categorizing ? "Asking Jev" : "Ask Jev")
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.categorizing || !model.settings.jevCategorizationEnabled)
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, entity in
                    if index > 0 { Divider().opacity(0.6) }
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(AttentionFormat.duration(entity.duration))
                                .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            Spacer(minLength: UIScale.pt(6))
                            AttentionCategoryMenu(model: model, entity: entity)
                        }
                        WrapHStack(spacing: UIScale.pt(6)) {
                            if entity.categorySource == .jev {
                                Button {
                                    model.assign(entity: entity, to: entity.category.id)
                                } label: {
                                    AttentionChip(
                                        title: "Keep \(entity.category.name)",
                                        color: AttentionPalette.category(
                                            entity.category, dark: dark),
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
                        }
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
                    ? (SurfaceWidget(rawValue: row.key)?.title ?? row.key) : row.key,
                value: row.duration, detail: nil,
                color: AttentionPalette.accent(dark))
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
                            detail: $0.sessions == 1 ? "1 session" : "\($0.sessions) sessions",
                            color: AttentionPalette.accent(dark))
                    })
                HStack(spacing: UIScale.pt(6)) {
                    ForEach(agents.kinds.prefix(4)) { kind in
                        AttentionChip(
                            title: "\(kind.key) \(AttentionFormat.duration(kind.working))",
                            color: AttentionPalette.accent(dark))
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
                                .foregroundStyle(DashSkin.inkSoft(dark))
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
