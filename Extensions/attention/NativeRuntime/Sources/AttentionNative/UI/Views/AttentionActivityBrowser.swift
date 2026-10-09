@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import SwiftUI

enum AttentionActivitySort: String, CaseIterable, Identifiable {
    case time = "Most time"
    case visits = "Most visits"
    case name = "Name"
    var id: String { rawValue }

    func sorted(_ entities: [AttentionEntity]) -> [AttentionEntity] {
        entities.sorted {
            switch self {
            case .time:
                $0.duration == $1.duration ? $0.name < $1.name : $0.duration > $1.duration
            case .visits:
                $0.visits == $1.visits ? $0.duration > $1.duration : $0.visits > $1.visits
            case .name: $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}

struct AttentionEntitiesPanel: View {
    @Bindable var model: AttentionPageModel
    let limit: Int
    @State private var search = ""
    @State private var sort = AttentionActivitySort.time
    @State private var source = "all"
    @State private var shown = 12
    @Environment(\.colorScheme) private var scheme

    private var entities: [AttentionEntity] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sort.sorted(
            model.summary.entities.filter { entity in
                (source == "all" || entity.source.rawValue == source
                    || (source == AttentionEventSource.browser.rawValue && entity.domain != nil)
                    || (source == AttentionEventSource.application.rawValue
                        && entity.bundleID != nil))
                    && (query.isEmpty
                        || ([entity.name, entity.category.name]
                            + entity.categoryDurations.keys.map { model.category($0).name }
                            + entity.details.map(\.name)).contains {
                                $0.localizedCaseInsensitiveContains(query)
                            })
            })
    }

    var body: some View {
        let items = entities
        let selected = items.first { $0.id == model.selectedEntityID } ?? items.first
        AttentionPanel(
            "Where time went",
            subtitle: "Select an activity to see its categories and every page or window.",
            trailing: {
                Button("Explore all activity") { model.section = .breakdown }
                    .buttonStyle(.edith(.secondary))
            }
        ) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    controls
                    Spacer()
                    resultCount(items)
                }
                VStack(alignment: .leading, spacing: 10) {
                    controls
                    resultCount(items)
                }
            }
            if items.isEmpty {
                AttentionEmpty(text: "No activity matches your search", symbol: "magnifyingglass")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: UIScale.pt(20)) {
                        activityList(items, selected: selected?.id)
                            .frame(minWidth: UIScale.pt(480), maxWidth: .infinity)
                        if let selected {
                            AttentionActivityInspector(model: model, entity: selected)
                                .frame(width: UIScale.pt(380))
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        activityList(items, selected: selected?.id)
                        if let selected {
                            AttentionActivityInspector(model: model, entity: selected)
                        }
                    }
                }
            }
        }
        .onChange(of: search) { shown = limit }
        .onChange(of: source) { shown = limit }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField; sortingControls
            }
            VStack(alignment: .leading, spacing: 10) {
                searchField; sortingControls
            }
        }
    }

    private var searchField: some View {
        TextField("Search apps, sites and titles", text: $search)
            .textFieldStyle(.roundedBorder).frame(width: UIScale.pt(240))
            .accessibilityLabel("Search activities")
    }

    private var sortingControls: some View {
        HStack(spacing: 10) {
            Picker("Source", selection: $source) {
                Text("All sources").tag("all")
                Text("Websites").tag(AttentionEventSource.browser.rawValue)
                Text("Applications").tag(AttentionEventSource.application.rawValue)
            }.fixedSize()
            Picker("Sort", selection: $sort) {
                ForEach(AttentionActivitySort.allCases) { Text($0.rawValue).tag($0) }
            }.fixedSize()
        }
    }

    private func resultCount(_ items: [AttentionEntity]) -> some View {
        Text(
            "\(items.count) activities · \(AttentionFormat.duration(items.reduce(0) { $0 + $1.duration }))"
        )
        .font(.system(size: UIScale.pt(12)))
        .foregroundStyle(.secondary)
    }

    private func activityList(_ items: [AttentionEntity], selected: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACTIVITY").frame(maxWidth: .infinity, alignment: .leading)
                Text("TIME").frame(width: UIScale.pt(74), alignment: .trailing)
                Text("SHARE").frame(width: UIScale.pt(52), alignment: .trailing)
            }
            .font(DashSkin.mono(10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            Group {
                LazyVStack(spacing: 4) {
                    ForEach(items.prefix(shown)) { entity in
                        Button {
                            model.selectedEntityID = entity.id
                        } label: {
                            activityRow(entity, selected: selected == entity.id)
                        }
                        .buttonStyle(.edith(.borderless))
                        .accessibilityLabel(
                            "\(entity.name), \(AttentionFormat.duration(entity.duration)), show details"
                        )
                    }
                }
            }
            if items.count > shown {
                Button("Show \(min(40, items.count - shown)) more of \(items.count)") {
                    shown += 40
                }
                .buttonStyle(.edith(.secondary))
            }
        }
    }

    private func activityRow(_ entity: AttentionEntity, selected: Bool) -> some View {
        let dark = scheme == .dark
        let categories = entity.categoryDurations.filter { $0.value > 0 }.count
        return HStack(spacing: UIScale.pt(10)) {
            AttentionEntityIcon(entity: entity, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(entity.name)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(categories > 1 ? "\(categories) categories" : entity.category.name)
                    Text("· \(entity.visits) visits")
                }
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                AttentionMixBar(
                    levels: entity.levels, total: entity.duration,
                    scale: model.summary.entities.first?.duration ?? 1
                )
                .frame(maxWidth: UIScale.pt(260))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(AttentionFormat.duration(entity.duration))
                .font(.system(size: UIScale.pt(14), weight: .semibold))
                .monospacedDigit()
                .frame(width: UIScale.pt(74), alignment: .trailing)
            Text(AttentionFormat.percent(entity.duration, of: model.summary.activeDuration))
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: UIScale.pt(52), alignment: .trailing)
        }
        .padding(10)
        .background(
            selected ? DashSkin.accent(dark).opacity(0.12) : DashSkin.paper2(dark),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(
                selected ? DashSkin.accent(dark).opacity(0.6) : .clear)
        )
        .foregroundStyle(DashSkin.ink(dark))
        .contentShape(Rectangle())
    }
}

struct AttentionActivityInspector: View {
    let model: AttentionPageModel
    let entity: AttentionEntity
    @State private var search = ""
    @State private var limit = 20
    @Environment(\.colorScheme) private var scheme

    private var details: [AttentionDetail] {
        entity.details.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.url?.localizedCaseInsensitiveContains(search) == true
        }
    }

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entity.name).font(DashSkin.heading(19)).lineLimit(2)
                    Text(
                        "\(AttentionFormat.duration(entity.duration)) active · \(entity.visits) visits"
                    )
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                AttentionCategoryMenu(model: model, entity: entity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("CATEGORY SPLIT").font(DashSkin.mono(10)).foregroundStyle(.secondary)
                ForEach(entity.categoryDurations.sorted { $0.value > $1.value }, id: \.key) {
                    id, duration in
                    Button {
                        model.filter(category: id)
                    } label: {
                        AttentionLabeledBar(
                            title: model.category(id).name, duration: duration,
                            total: entity.duration,
                            color: AttentionPalette.category(model.category(id), dark: dark))
                    }
                    .buttonStyle(.edith(.borderless))
                }
            }
            Divider()
            HStack {
                Text("PAGES AND WINDOWS").font(DashSkin.mono(10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(entity.details.count)").font(DashSkin.mono(10)).foregroundStyle(.secondary)
            }
            TextField("Find a title or URL", text: $search)
                .textFieldStyle(.roundedBorder)
            if details.isEmpty {
                Text(
                    entity.details.isEmpty
                        ? "No page or window title was recorded." : "No titles match this search."
                )
                .font(.system(size: UIScale.pt(12))).foregroundStyle(.secondary)
            } else {
                Group {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(details.prefix(limit)) { detail in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(detail.name)
                                        .font(.system(size: UIScale.pt(12), weight: .medium))
                                        .lineLimit(2).help(detail.name)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(AttentionFormat.duration(detail.duration))
                                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                                        .monospacedDigit().fixedSize()
                                }
                                HStack {
                                    Text(model.category(detail.categoryID).name)
                                    Spacer()
                                    Text(
                                        AttentionFormat.percent(
                                            detail.duration, of: entity.duration))
                                }
                                .font(.system(size: UIScale.pt(10.5))).foregroundStyle(.secondary)
                                if let url = detail.url {
                                    Text(url).font(.system(size: UIScale.pt(10)))
                                        .foregroundStyle(.secondary).lineLimit(1).help(url)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 9)
                            Divider().opacity(0.5)
                        }
                        if details.count > limit {
                            Button("Show \(min(40, details.count - limit)) more titles") {
                                limit += 40
                            }
                            .buttonStyle(.edith(.secondary)).padding(.top, 10)
                        }
                    }
                }
            }
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: entity.id) {
            search = ""; limit = 20
        }
    }
}

struct AttentionLabeledBar: View {
    let title: String
    let duration: TimeInterval
    let total: TimeInterval
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(AttentionFormat.duration(duration)).monospacedDigit().fixedSize()
                Text(AttentionFormat.percent(duration, of: total))
                    .foregroundStyle(.secondary).monospacedDigit().frame(
                        width: UIScale.pt(40), alignment: .trailing)
            }
            .font(.system(size: UIScale.pt(12), weight: .medium))
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(
                            width: geometry.size.width * min(1, duration / max(1, total)))
                    }
            }
            .frame(height: UIScale.pt(5))
        }
    }
}
