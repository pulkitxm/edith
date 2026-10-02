import AppKit
import EdithCore
import EdithKit
import SwiftUI

struct AttentionBreakdownItem: Identifiable {
    var id: String { key }
    var key: String
    var label: String
    var duration: TimeInterval
    var categories: [String: TimeInterval]
    var names: [String]
    var entity: AttentionEntity? = nil

    var subtitle: String? {
        let candidates = names + [entity?.domain, entity?.category.name].compactMap { $0 }
        var seen = Set([label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
        let distinct = candidates.compactMap { value -> String? in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }
        return distinct.isEmpty ? nil : distinct.joined(separator: ", ")
    }
    var interactions: Int
}

enum AttentionBreakdownSort: String, CaseIterable, Identifiable {
    case time = "Most time"
    case name = "Name"
    case inputs = "Most inputs"
    var id: String { rawValue }

    func sorted(_ rows: [AttentionBreakdownItem]) -> [AttentionBreakdownItem] {
        rows.sorted {
            switch self {
            case .time: $0.duration == $1.duration ? $0.key < $1.key : $0.duration > $1.duration
            case .name: $0.label.localizedStandardCompare($1.label) == .orderedAscending
            case .inputs:
                $0.interactions == $1.interactions
                    ? $0.duration > $1.duration : $0.interactions > $1.interactions
            }
        }
    }
}

struct AttentionBreakdownView: View {
    @Bindable var model: AttentionPageModel
    @State private var sort = AttentionBreakdownSort.time
    @State private var selected: String?
    @State private var limit = 40
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private func rows(_ dimension: AttentionDimension?) -> [AttentionBreakdownItem] {
        guard let dimension else { return [] }
        return sort.sorted(
            dimension.rows.compactMap { row in
                let duration = model.matches(
                    categories: row.categories, levels: row.levels, spheres: row.spheres)
                let label =
                    dimension.key == AttentionTag.page
                    ? (MainDestination(rawValue: row.key)?.title ?? row.key) : row.key
                guard duration > 0, model.matchesSearch([label] + row.entityNames) else {
                    return nil
                }
                return AttentionBreakdownItem(
                    key: row.key, label: label, duration: duration, categories: row.categories,
                    names: row.entityNames,
                    entity: model.summary.entities.first { row.entityIDs.contains($0.id) },
                    interactions: row.interactions)
            })
    }

    var body: some View {
        let dimensions = model.summary.dimensions
        let dimension = dimensions.first { $0.key == model.breakdownDimension } ?? dimensions.first
        let rows = rows(dimension)
        let total = rows.reduce(0) { $0 + $1.duration }
        let selection = rows.first { $0.key == selected } ?? rows.first
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            AttentionFilterBar(model: model)
            AttentionPanel(
                "Activity explorer",
                subtitle: "Group time by app, category, title, URL, profile or recorded context.",
                trailing: {
                    HStack(spacing: 10) {
                        Picker("Group by", selection: $model.breakdownDimension) {
                            ForEach(dimensions) { Text($0.title).tag($0.key) }
                        }.fixedSize()
                        Button {
                            copy(rows, title: dimension?.title ?? "Activity")
                        } label: {
                            Label("Copy CSV", systemImage: "doc.on.doc")
                        }.buttonStyle(.edith(.secondary)).disabled(rows.isEmpty)
                    }
                }
            ) {
                HStack(spacing: UIScale.pt(28)) {
                    metric("Matching time", value: AttentionFormat.duration(total))
                    metric(
                        "Share of active",
                        value: AttentionFormat.percent(total, of: model.summary.activeDuration))
                    metric("Groups", value: "\(rows.count)")
                    Spacer(minLength: 0)
                    Picker("Sort", selection: $sort) {
                        ForEach(AttentionBreakdownSort.allCases) { Text($0.rawValue).tag($0) }
                    }.fixedSize()
                }
                if rows.isEmpty {
                    AttentionEmpty(
                        text: dimensions.isEmpty
                            ? "No activity recorded in this period" : "Nothing matches the filters",
                        symbol: "magnifyingglass")
                } else {
                    ranking(rows)
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: UIScale.pt(24)) {
                            table(rows, total: total, selected: selection?.key)
                                .frame(minWidth: UIScale.pt(480), maxWidth: .infinity)
                            if let selection { detail(selection).frame(width: UIScale.pt(340)) }
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            table(rows, total: total, selected: selection?.key)
                            if let selection { detail(selection) }
                        }
                    }
                }
            }
        }
        .onChange(of: model.breakdownDimension) {
            selected = nil; limit = 40
        }
        .onChange(of: model.searchText) { limit = 40 }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            Text(value).font(DashSkin.heading(22)).monospacedDigit()
        }
    }

    private func ranking(_ rows: [AttentionBreakdownItem]) -> some View {
        let top = Array(AttentionBreakdownSort.time.sorted(rows).prefix(8))
        let maximum = max(1, top.first?.duration ?? 0)
        let accent = DashSkin.accent(scheme == .dark)
        return VStack(spacing: UIScale.pt(8)) {
            ForEach(top) { row in
                Button {
                    selected = row.key
                } label: {
                    HStack(spacing: UIScale.pt(12)) {
                        Text(row.label).lineLimit(1)
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .frame(width: UIScale.pt(compact ? 140 : 230), alignment: .trailing)
                            .help(row.label)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(
                                            accent.opacity(
                                                selected == nil || selected == row.key ? 1 : 0.35)
                                        )
                                        .frame(width: geometry.size.width * row.duration / maximum)
                                }
                        }
                        .frame(height: UIScale.pt(16))
                        Text(AttentionFormat.duration(row.duration))
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .monospacedDigit()
                            .frame(width: UIScale.pt(80), alignment: .leading)
                    }
                    .foregroundStyle(DashSkin.ink(scheme == .dark))
                    .padding(.vertical, UIScale.pt(5)).contentShape(Rectangle())
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel(
                    "\(row.label), \(AttentionFormat.duration(row.duration)), show details")
            }
            Text("Top \(top.count) by active time · select a bar for details")
                .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func table(_ rows: [AttentionBreakdownItem], total: TimeInterval, selected: String?)
        -> some View
    {
        VStack(spacing: 4) {
            HStack {
                Text("ACTIVITY").frame(maxWidth: .infinity, alignment: .leading)
                Text("TIME").frame(width: UIScale.pt(80), alignment: .trailing)
                Text("SHARE").frame(width: UIScale.pt(55), alignment: .trailing)
            }.font(DashSkin.mono(10)).foregroundStyle(.secondary).padding(10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows.prefix(limit)) { row in
                        Button {
                            self.selected = row.key
                        } label: {
                            HStack(spacing: 10) {
                                if let entity = row.entity {
                                    AttentionEntityIcon(entity: entity, size: 28)
                                } else {
                                    AttentionResolvedIcon(
                                        descriptor: .symbol("square.grid.2x2"),
                                        fallbackColor: DashSkin.inkSoft(scheme == .dark), size: 28)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.label).font(
                                        .system(size: UIScale.pt(12.5), weight: .medium)
                                    ).lineLimit(2).help(row.label)
                                    if let subtitle = row.subtitle {
                                        Text(subtitle).font(.system(size: UIScale.pt(11)))
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(AttentionFormat.duration(row.duration)).monospacedDigit().font(
                                    .system(size: UIScale.pt(13), weight: .semibold)
                                ).frame(width: UIScale.pt(80), alignment: .trailing)
                                Text(AttentionFormat.percent(row.duration, of: total))
                                    .monospacedDigit().font(.system(size: UIScale.pt(12)))
                                    .foregroundStyle(.secondary).frame(
                                        width: UIScale.pt(55), alignment: .trailing)
                            }
                            .padding(10)
                            .background(
                                (selected == row.key
                                    ? DashSkin.accent(scheme == .dark).opacity(0.12)
                                    : DashSkin.paper2(scheme == .dark)),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(DashSkin.ink(scheme == .dark)).contentShape(
                                Rectangle())
                        }.buttonStyle(.edith(.borderless))
                    }
                }
            }.frame(height: UIScale.pt(min(450, CGFloat(min(rows.count, limit)) * 57)))
            if rows.count > limit {
                Button("Show \(min(40, rows.count - limit)) more of \(rows.count)") { limit += 40 }
                    .buttonStyle(.edith(.secondary)).padding(.top, 8)
            }
        }
    }

    private func detail(_ row: AttentionBreakdownItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(row.label).font(DashSkin.heading(17)).lineLimit(4).textSelection(.enabled)
            Text("\(AttentionFormat.duration(row.duration)) matching time").font(
                DashSkin.heading(23)
            ).monospacedDigit()
            if model.hasFilters {
                Text(
                    "Filtered from \(AttentionFormat.duration(row.categories.values.reduce(0, +))) total time in this group."
                ).font(.system(size: UIScale.pt(12))).foregroundStyle(.secondary)
            }
            Text("FULL CATEGORY SPLIT").font(DashSkin.mono(10)).foregroundStyle(.secondary)
            ForEach(row.categories.sorted { $0.value > $1.value }, id: \.key) { key, duration in
                Button {
                    model.filter(category: key, navigate: false)
                } label: {
                    AttentionLabeledBar(
                        title: model.category(key).name, duration: duration,
                        total: row.categories.values.reduce(0, +),
                        color: AttentionPalette.category(model.category(key), dark: scheme == .dark)
                    )
                }.buttonStyle(.edith(.borderless))
            }
            if row.interactions > 0 {
                Text("\(AttentionFormat.count(row.interactions)) inputs recorded across this group")
                    .font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(scheme == .dark), in: RoundedRectangle(cornerRadius: 12))
    }

    private func copy(_ rows: [AttentionBreakdownItem], title: String) {
        let total = rows.reduce(0) { $0 + $1.duration }
        let lines =
            ["\(DoubleQuoted.wrap(title)),seconds,minutes,share_percent"]
            + rows.map {
                "\(DoubleQuoted.wrap($0.label)),\(String(format: "%.0f", $0.duration)),\(String(format: "%.2f", $0.duration / 60)),\(String(format: "%.2f", total > 0 ? $0.duration / total * 100 : 0))"
            }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        model.message = "Copied \(rows.count) rows"
    }
}
