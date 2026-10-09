import EdithExtensionSupport
import SwiftUI

public struct SurfaceSnapshotContent: View {
    let tile: SurfaceTile
    let snapshot: SurfaceSnapshot
    let perform: (SurfaceAction) -> Void

    public init(
        tile: SurfaceTile, snapshot: SurfaceSnapshot, perform: @escaping (SurfaceAction) -> Void
    ) {
        self.tile = tile; self.snapshot = snapshot; self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(tile.dense ? 8 : 12)) {
            let metrics = snapshot.metrics.filter { tile.shows($0.id) }
            if !metrics.isEmpty {
                LazyVGrid(columns: tile.metricGrid(minimum: 120)) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                            Text(metric.value).font(.edithText(.title3)).monospacedDigit()
                            Text(metric.title).font(.edithText(.caption)).foregroundStyle(
                                .secondary)
                            if let fraction = metric.fraction, tile.shows("progress") {
                                ProgressView(value: fraction)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if tile.shows("items") {
                ForEach(
                    Array(
                        snapshot.rows.filter { $0.field.map(tile.shows) ?? true }.prefix(
                            tile.itemLimit))
                ) { row in
                    VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                        HStack(alignment: .top) {
                            Image(systemName: row.icon)
                            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                                Text(row.title).lineLimit(tile.dense ? 1 : 2).accessibilityLabel(
                                    row.title)
                                if tile.showDetails, tile.shows("metadata"), !row.detail.isEmpty {
                                    Text(row.detail).font(.edithText(.caption)).foregroundStyle(
                                        .secondary
                                    ).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if tile.shows("status"), !row.value.isEmpty {
                                Text(row.value).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.font(.edithText(.callout))
                        if let progress = row.progress, tile.shows("progress") {
                            ProgressView(value: progress)
                        }
                        if tile.showActions { actions(row.actions) }
                    }
                }
            }
            if let message = snapshot.message {
                Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if tile.showActions { actions(snapshot.actions) }
            if tile.showDetails, tile.shows("updated"), let updatedAt = snapshot.updatedAt {
                Text("Updated " + updatedAt.formatted(date: .omitted, time: .shortened)).font(
                    .edithText(.caption2)
                ).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ values: [SurfaceAction]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { actionButtons(values) }
            VStack(alignment: .leading) { actionButtons(values) }
        }
    }

    private func actionButtons(_ values: [SurfaceAction]) -> some View {
        ForEach(values.filter { $0.field.map(tile.shows) ?? true }) { action in
            Button {
                perform(action)
            } label: {
                Label(action.title, systemImage: action.icon)
            }
            .buttonStyle(.edith(.secondary)).font(.edithText(.caption))
        }
    }
}
