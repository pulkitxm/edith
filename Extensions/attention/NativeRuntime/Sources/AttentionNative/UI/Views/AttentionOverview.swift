internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import SwiftUI

struct AttentionOverview: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.compactLayout) private var compact

    private var summary: AttentionSummary { model.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
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
            VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                leading()
                trailing()
            }
        } else {
            HStack(alignment: .top, spacing: UIScale.pt(PageMetrics.sectionSpacing)) {
                leading().frame(maxWidth: .infinity, alignment: .top)
                trailing().frame(maxWidth: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.attentionPanelFills, true)
        }
    }
}

struct AttentionHeadline: View {
    let model: AttentionPageModel
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
        PageMetricGrid(maximumColumns: 4) {
            PageMetric(
                title: "Screen time",
                value: AttentionFormat.duration(
                    summary.screenTime(excludingIdle: model.excludeIdleTime)),
                detail: model.excludeIdleTime
                    ? "idle and locked time excluded" : "includes idle and locked time",
                icon: .clock, tint: quiet)
            PageMetric(
                title: "Idle / locked", value: AttentionFormat.duration(summary.idleDuration),
                detail: "idle after \(Int(model.settings.idleThreshold / 60))m without input",
                icon: .moon, tint: quiet)
            PageMetric(
                title: "Active", value: AttentionFormat.duration(active),
                detail:
                    "\(AttentionFormat.duration(summary.duration(AttentionSphere.work))) work · \(AttentionFormat.duration(summary.duration(AttentionSphere.personal))) personal",
                icon: .cursor, tint: quiet)
            PageMetric(
                title: "Productive", value: AttentionFormat.duration(productive),
                detail: AttentionFormat.share(
                    productive, of: active, previous: previous?.productive), icon: .scan,
                tint: accent)
            PageMetric(
                title: "Distracting", value: AttentionFormat.duration(distracting),
                detail: AttentionFormat.share(
                    distracting, of: active, previous: previous?.distracting),
                icon: .arrowDownRight,
                tint: AttentionPalette.level(.veryDistracting, dark: dark))
            PageMetric(
                title: "Deep work", value: AttentionFormat.duration(summary.deepWorkDuration),
                detail: summary.focusBlocks.isEmpty
                    ? "no block of \(Int(model.settings.focusBlockMinimum / 60))m yet"
                    : "\(summary.focusBlocks.count) blocks, longest \(AttentionFormat.duration(longestBlock))",
                icon: .companion, tint: quiet)
            PageMetric(
                title: "Switches", value: String(format: "%.0f/h", perHour),
                detail:
                    "\(summary.contextSwitches) total · \(AttentionFormat.duration(summary.medianStretch)) median stretch",
                icon: .sync, tint: quiet)
            PageMetric(
                title: "Agent work", value: AttentionFormat.duration(summary.agents.working),
                detail: summary.agents.isEmpty
                    ? "no agent activity recorded"
                    : AttentionFormat.joined(
                        "peak \(summary.agents.peakConcurrent) at once",
                        AttentionFormat.delta(summary.agents.working, previous?.agentWorking)),
                icon: .herdr, tint: quiet)
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
                AttentionEmpty(text: "No active time in this period", icon: .moon)
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
                    .font(.edithText(.subheadline).weight(.semibold))
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
                AttentionEmpty(text: "No active hours yet", icon: .clock)
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
                                        Label(category.name, edith: .check)
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
                            Label(level.title, edith: .check)
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
                            Label(sphere.title, edith: .check)
                        } else {
                            Text(sphere.title)
                        }
                    }
                }
            }
        } label: {
            EdithIcon.tag.image()
        }
        .borderlessMenu()
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
                                    .font(.edithText(.callout).weight(.medium))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Text(
                                    entity.details.first?.name
                                        ?? AttentionFormat.duration(entity.duration)
                                )
                                .font(.edithText(.caption))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(AttentionFormat.duration(entity.duration))
                                .font(.edithText(.subheadline).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                            Spacer(minLength: UIScale.pt(6))
                            AttentionCategoryMenu(model: model, entity: entity)
                        }
                        WrapHStack(spacing: UIScale.pt(6)) {
                            if entity.categorySource == .jev {
                                let color = AttentionPalette.category(entity.category, dark: dark)
                                PageChip(
                                    "Keep \(entity.category.name)", dot: color, active: true,
                                    tint: color
                                ) {
                                    model.assign(entity: entity, to: entity.category.id)
                                }
                            }
                            ForEach(quick.filter { $0.id != entity.category.id }.prefix(4)) {
                                category in
                                PageChip(
                                    category.name,
                                    dot: AttentionPalette.category(category, dark: dark)
                                ) {
                                    model.assign(entity: entity, to: category.id)
                                }
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
                            .font(.edithText(.callout))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.edithText(.caption))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                        }
                        Spacer(minLength: UIScale.pt(6))
                        Text(AttentionFormat.duration(row.value))
                            .font(.edithText(.subheadline).weight(.medium))
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
                    ? (AttentionPageTitles.title(row.key) ?? row.key) : row.key,
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
                    icon: .window)
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
                AttentionEmpty(text: "No switches yet", icon: .arrowSwap)
            } else {
                Text("Most common switches")
                    .font(.edithText(.subheadline).weight(.semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    ForEach(summary.transitions.prefix(6)) { transition in
                        HStack(spacing: UIScale.pt(6)) {
                            Text(transition.from).lineLimit(1)
                            EdithIconView(.arrowRight)
                                .font(.edithText(.caption))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                            Text(transition.to).lineLimit(1)
                            Spacer(minLength: UIScale.pt(6))
                            Text("\(transition.count)×")
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                        .font(.edithText(.callout))
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
                .font(.edithText(.caption))
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
                    .font(.edithText(.subheadline))
            }
        ) {
            if agents.isEmpty {
                AttentionEmpty(
                    text: model.settings.agentTrackingEnabled
                        ? "Agent work appears as Herdr sessions run"
                        : "Agent tracking is off in Attention settings",
                    icon: .herdr)
            } else {
                AttentionRankList(
                    rows: agents.machines.prefix(5).map {
                        AttentionRankRow(
                            label: $0.key, value: $0.working,
                            detail: $0.sessions == 1 ? "1 session" : "\($0.sessions) sessions",
                            color: AttentionPalette.accent(dark))
                    })
                WrapHStack(
                    spacing: UIScale.pt(PageMetrics.controlSpacing),
                    lineSpacing: UIScale.pt(PageMetrics.controlSpacing)
                ) {
                    ForEach(agents.kinds.prefix(4)) { kind in
                        PageChipLabel(
                            "\(kind.key) \(AttentionFormat.duration(kind.working))",
                            dot: AttentionPalette.accent(dark)
                        )
                        .pageChipChrome()
                        .fixedSize()
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
                AttentionEmpty(text: "Nothing played in this period", icon: .music)
            } else {
                VStack(spacing: UIScale.pt(7)) {
                    ForEach(music.prefix(6)) { item in
                        HStack(spacing: UIScale.pt(10)) {
                            EdithIconView(.music)
                                .foregroundStyle(DashSkin.inkSoft(dark))
                                .frame(width: UIScale.pt(20))
                            VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                                Text(item.title)
                                    .font(.edithText(.callout))
                                    .foregroundStyle(DashSkin.ink(dark))
                                    .lineLimit(1)
                                Text(
                                    [item.artist, item.service].compactMap { $0 }
                                        .joined(separator: " · ")
                                )
                                .font(.edithText(.caption))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .lineLimit(1)
                            }
                            Spacer(minLength: UIScale.pt(6))
                            Text(AttentionFormat.duration(item.duration))
                                .font(.edithText(.subheadline))
                                .monospacedDigit()
                                .foregroundStyle(DashSkin.inkSoft(dark))
                        }
                    }
                }
            }
        }
    }
}

enum AttentionPageTitles {
    static let titles: [String: String] = [
        "home": "Home", "agents": "Agents & Terminal", "usage": "Usage", "herdr": "Agents",
        "quinjet": "Code Review", "companion": "Memory", "plugins": "Plugins",
        "machines": "Machines", "docs": "Docs", "utilities": "Mac Utilities",
        "appMaintenance": "App Updates", "homebrew": "Homebrew", "cleaner": "Cleaner",
        "blitztree": "Disk Map", "system": "Running Apps", "calendar": "Calendar",
        "desk": "Desk", "media": "Media", "studio": "Studio", "timeLapse": "Screen Recorder",
        "virtualCamera": "Virtual Camera", "music": "Music", "downloads": "Downloads",
        "socialManager": "Social Manager", "developer": "Developer & Data",
        "database": "Database", "codeStats": "Code Stats", "seoAudit": "Site Audit",
        "latex": "LaTeX", "attention": "Attention", "extensions": "Extensions",
        "settings": "Settings", "about": "About",
    ]

    static func title(_ key: String) -> String? { titles[key] }
}
