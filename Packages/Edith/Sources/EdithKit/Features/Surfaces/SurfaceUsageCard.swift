import Charts
import SwiftUI

public struct SurfaceUsageCard: View {
    let tile: SurfaceTile
    let active: Bool
    let open: (String) -> Void
    @State private var snapshot: SurfaceUsageSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @Environment(\.surfacePresentation) private var presentation
    @Environment(\.surfaceFillHeight) private var fillHeight
    @Environment(\.surfaceSampleContent) private var sampleContent

    public init(tile: SurfaceTile, active: Bool, open: @escaping (String) -> Void) {
        self.tile = tile; self.active = active; self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(tile.dense ? 8 : 12)) {
            if tile.showTitle || tile.showActions {
                HStack {
                    if tile.showTitle {
                        Label(tile.displayTitle, systemImage: tile.widget.icon)
                            .font(.edithText(.headline)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if tile.showActions {
                        Button {
                            retry += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh usage").accessibilityLabel("Refresh usage")
                        Button {
                            open("usage")
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .help("Open Agent Usage").accessibilityLabel("Open Agent Usage")
                    }
                }.buttonStyle(.edith(.borderless))
            }
            if let value = sampleContent ? SurfaceSampleData.usage(tile) : snapshot {
                data(value).presenterCover(.usage)
            } else if load.isRunning {
                LoadingIndicator()
            } else if load.errorMessage == nil {
                Text("No usage records yet. Refresh Agent Usage to collect your history.")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if let error = load.errorMessage {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { retry += 1 }.buttonStyle(.edith(.secondary))
            }
        }
        .padding(UIScale.pt(presentation?.padding ?? (tile.dense ? 10 : 14)))
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12))
        )
        .task(
            id: "\(active):\(sampleContent):\(tile.days):\(tile.sourceIDs?.sorted() ?? []):\(retry)"
        ) {
            guard !sampleContent, active || retry > 0 else { return }
            repeat {
                let request = load.begin()
                do {
                    let next = try await SurfaceUsageStore.shared.snapshot(tile: tile)
                    guard load.isCurrent(request), !Task.isCancelled else { return }
                    snapshot = next; load.complete(request)
                } catch {
                    guard load.isCurrent(request), !Task.isCancelled else { return }
                    if (error as? CocoaError)?.code == .fileReadNoSuchFile {
                        load.complete(request, empty: true)
                    } else {
                        load.fail(request, error: error)
                    }
                }
                guard active else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
    }

    @ViewBuilder private func data(_ value: SurfaceUsageSnapshot) -> some View {
        LazyVGrid(columns: tile.metricGrid(minimum: 88), alignment: .leading, spacing: 8) {
            if tile.shows("today") { metric("Today", value.today) }
            if tile.shows("week") { metric("Last 7 days", value.week) }
            if tile.shows("period") { metric("Last \(tile.days) days", value.total) }
        }
        if tile.showDetails {
            if tile.shows("chart") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Daily \(value.chartUsesTokens ? "tokens" : "cost") · \(value.activeDays) active days"
                    )
                    .font(.edithText(.caption2)).foregroundStyle(.secondary)
                    Chart(value.days) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value(
                                value.chartUsesTokens ? "Tokens" : "Cost",
                                value.chartUsesTokens ? day.tokens : day.cost)
                        )
                        .foregroundStyle(tile.highlightColor)
                        .accessibilityLabel(day.date.formatted(.dateTime.month().day()))
                        .accessibilityValue(
                            value.chartUsesTokens ? tokens(day.tokens) : money(day.cost))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: max(1, tile.days / 4))) {
                            AxisValueLabel(format: .dateTime.day())
                        }
                    }
                    .frame(height: UIScale.pt(tile.dense ? 60 : 90))
                }
            }
            if tile.shows("providers") {
                breakdown("Providers", value.providers)
            }
            if tile.shows("models") {
                breakdown("Models", value.models)
            }
            if value.total.tokens == 0, value.total.cost == 0 {
                Text("No usage in this period for the selected sources.")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if tile.shows("updated"), let date = value.updatedAt {
                Text("Updated " + date.formatted(.dateTime.hour().minute()))
                    .font(.edithText(.caption2)).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: SurfaceUsageSnapshot.Total) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(money(value.cost)).font(.edithText(tile.dense ? .headline : .title3))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
            if tile.shows("tokens") {
                Text(tokens(value.tokens) + " tokens").font(.edithText(.caption2))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func breakdown(
        _ title: String, _ rows: [SurfaceUsageSnapshot.Breakdown]
    ) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.edithText(.caption2)).foregroundStyle(.secondary)
                ForEach(Array(rows.prefix(tile.itemLimit))) { row in
                    HStack(spacing: 8) {
                        Circle().fill(tile.highlightColor).frame(width: 5, height: 5)
                        Text(row.title).lineLimit(1).help(row.title)
                        Spacer(minLength: 4)
                        if tile.shows("tokens") {
                            Text(tokens(row.total.tokens)).foregroundStyle(.secondary)
                        }
                        Text(money(row.total.cost)).monospacedDigit()
                    }.font(.edithText(.caption))
                }
                if rows.count > tile.itemLimit {
                    Text("+\(rows.count - tile.itemLimit) more")
                        .font(.edithText(.caption2)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }
    private func tokens(_ value: Double) -> String {
        for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where value >= scale {
            return String(format: "%.1f%@", value / scale, suffix)
        }
        return String(format: "%.0f", value)
    }
}
