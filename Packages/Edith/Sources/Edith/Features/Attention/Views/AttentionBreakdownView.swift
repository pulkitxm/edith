import AppKit
import EdithKit
import SwiftUI

struct AttentionBreakdownView: View {
    @Bindable var model: AttentionPageModel
    @Environment(\.colorScheme) private var scheme

    private struct Row: Identifiable {
        var id: String { key }
        var key: String
        var label: String
        var duration: TimeInterval
        var categories: [String: TimeInterval]
        var names: [String]
        var interactions: Int
        var levels: [String: TimeInterval]
    }

    private func label(_ key: String, dimension: String) -> String {
        dimension == AttentionTag.page ? (MainDestination(rawValue: key)?.title ?? key) : key
    }

    private func rows(_ dimension: AttentionDimension?) -> [Row] {
        guard let dimension else { return [] }
        return dimension.rows.compactMap { row -> Row? in
            let duration = model.matches(
                categories: row.categories, levels: row.levels, spheres: row.spheres)
            let label = label(row.key, dimension: dimension.key)
            guard duration > 0, model.matchesSearch([label] + row.entityNames) else {
                return nil
            }
            return Row(
                key: row.key, label: label, duration: duration, categories: row.categories,
                names: row.entityNames, interactions: row.interactions, levels: row.levels)
        }
        .sorted { $0.duration > $1.duration }
    }

    var body: some View {
        let dark = scheme == .dark
        let dimensions = model.summary.dimensions
        let dimension = dimensions.first { $0.key == model.breakdownDimension } ?? dimensions.first
        let rows = rows(dimension)
        let top = rows.first?.duration ?? 1
        let filteredTotal = rows.reduce(0) { $0 + $1.duration }
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            AttentionFilterBar(model: model)
            AttentionPanel(
                dimension?.title ?? "Breakdown",
                subtitle: rows.isEmpty
                    ? nil
                    : "\(rows.count) rows · \(AttentionFormat.duration(filteredTotal)) of \(AttentionFormat.duration(model.summary.activeDuration)) active",
                trailing: {
                    HStack(spacing: UIScale.pt(8)) {
                        Picker("Group by", selection: $model.breakdownDimension) {
                            ForEach(dimensions) { item in
                                Text(item.title).tag(item.key)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Button {
                            copy(rows, title: dimension?.title ?? "Key")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.edith(.iconOnly))
                        .help("Copy as CSV")
                        .disabled(rows.isEmpty)
                    }
                }
            ) {
                if dimensions.isEmpty {
                    AttentionEmpty(
                        text: "No activity to break down yet", symbol: "square.stack.3d.up")
                } else if rows.isEmpty {
                    AttentionEmpty(
                        text: "Nothing matches the filters", symbol: "line.3.horizontal.decrease")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.prefix(80).enumerated()), id: \.element.id) {
                            index, row in
                            if index > 0 { Divider().opacity(0.5) }
                            HStack(spacing: UIScale.pt(12)) {
                                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                                    HStack(spacing: UIScale.pt(6)) {
                                        Text(row.label)
                                            .font(.system(size: UIScale.pt(12.5), weight: .medium))
                                            .foregroundStyle(DashSkin.ink(dark))
                                            .lineLimit(1)
                                            .help(row.label)
                                        if !row.names.isEmpty, row.names != [row.label] {
                                            Text(row.names.joined(separator: ", "))
                                                .font(.system(size: UIScale.pt(10.5)))
                                                .foregroundStyle(DashSkin.inkFaint(dark))
                                                .lineLimit(1)
                                        }
                                    }
                                    AttentionMixBar(
                                        levels: row.levels,
                                        total: AttentionPageModel.total(row.levels), scale: top)
                                }
                                VStack(alignment: .trailing, spacing: UIScale.pt(2)) {
                                    Text(AttentionFormat.duration(row.duration))
                                        .font(.system(size: UIScale.pt(12), weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(DashSkin.ink(dark))
                                    Text(
                                        row.interactions > 0
                                            ? "\(AttentionFormat.percent(row.duration, of: filteredTotal)) · \(AttentionFormat.count(row.interactions)) inputs"
                                            : AttentionFormat.percent(
                                                row.duration, of: filteredTotal)
                                    )
                                    .font(.system(size: UIScale.pt(10)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                }
                                .frame(minWidth: UIScale.pt(90), alignment: .trailing)
                            }
                            .padding(.vertical, UIScale.pt(7))
                        }
                    }
                }
            }
        }
    }

    private func copy(_ rows: [Row], title: String) {
        func field(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let lines =
            ["\(field(title)),minutes,top category"]
            + rows.map { row in
                let category =
                    row.categories.max { $0.value < $1.value }.map {
                        model.category($0.key).name
                    } ?? ""
                return
                    "\(field(row.label)),\(String(format: "%.1f", row.duration / 60)),\(field(category))"
            }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        model.message = "Copied \(rows.count) rows"
    }
}
