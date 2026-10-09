import AppKit
import EdithCore
import EdithKit
import SwiftUI

struct AttentionBreakdownView: View {
    @Bindable var model: AttentionPageModel
    @State private var selected: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let dimensions = model.summary.dimensions
        let dimension = dimensions.first { $0.key == model.breakdownDimension } ?? dimensions.first
        let rows = model.breakdown.rows
        let total = model.breakdown.total
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: UIScale.pt(28)) {
                        metrics.fixedSize()
                        Spacer(minLength: UIScale.pt(16))
                        sortPicker
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(14)) {
                        metrics
                        sortPicker
                    }
                }
                if model.breakdownLoad.isRunning {
                    LoadingIndicator("Updating activity…")
                }
                if rows.isEmpty && !model.breakdownLoad.isRunning {
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
            selected = nil
        }
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: UIScale.pt(28)) {
            metric("Matching time", value: AttentionFormat.duration(model.breakdown.total))
            metric(
                "Share of active",
                value: AttentionFormat.percent(
                    model.breakdown.total, of: model.summary.activeDuration))
            metric("Groups", value: "\(model.breakdown.rows.count)")
        }
        .fixedSize()
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $model.breakdownSort) {
            ForEach(AttentionBreakdownSort.allCases) { Text($0.rawValue).tag($0) }
        }.fixedSize()
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: UIScale.pt(11))).foregroundStyle(.secondary)
            Text(value).font(DashSkin.heading(22)).monospacedDigit()
        }
    }

    private func ranking(_ rows: [AttentionBreakdownItem]) -> some View {
        let top = Array(model.breakdown.top.prefix(compact ? 4 : 8))
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
        Table(
            rows,
            selection: Binding(get: { self.selected ?? selected }, set: { self.selected = $0 })
        ) {
            SwiftUI.TableColumn("Activity") { row in
                HStack(spacing: UIScale.pt(8)) {
                    if let entity = row.entity {
                        AttentionEntityIcon(entity: entity, size: 24)
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                        Text(row.label).font(.edithText(.body)).lineLimit(1).help(row.label)
                        if let subtitle = row.subtitle {
                            Text(subtitle).font(.edithText(.caption)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, UIScale.pt(4))
            }
            .width(min: UIScale.pt(160), ideal: UIScale.pt(280))
            SwiftUI.TableColumn("Time") { row in
                Text(AttentionFormat.duration(row.duration)).monospacedDigit()
            }
            .width(UIScale.pt(90))
            SwiftUI.TableColumn("Share") { row in
                Text(AttentionFormat.percent(row.duration, of: total)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(UIScale.pt(70))
        }
        .tableStyle(.inset)
        .frame(height: UIScale.pt(420))
        .accessibilityLabel("Activity groups")
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
