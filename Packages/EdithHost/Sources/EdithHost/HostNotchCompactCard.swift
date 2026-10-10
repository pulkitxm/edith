import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithHostCore
import SwiftUI

struct HostNotchCompactCard: View {
    let model: HostNotchCompactCardModel
    let layout: SurfaceLayout
    let measured: (Double) -> Void
    private var tile: SurfaceTile { model.origin.tile }
    private var presentation: SurfacePresentation { .init(tile: tile, layout: layout) }
    private var projected: [HostNotchCompactProvider] {
        model.providers.map {
            .init(
                id: $0.id, version: $0.version,
                snapshot: SurfaceCommandService.project($0.snapshot, tile: tile))
        }
    }
    private var rows: [ScopedRow] {
        projected.flatMap { provider in
            provider.snapshot.rows.map { ScopedRow(providerID: provider.id, row: $0) }
        }
    }

    var body: some View {
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
                            model.requestRefresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh widget").accessibilityLabel("Refresh " + tile.displayTitle)
                        Button {
                            if let provider = model.admittedVersions?.keys.sorted().first {
                                model.requestOpen(providerID: provider)
                            }
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .help("Open " + tile.widget.title).accessibilityLabel(
                            "Open " + tile.widget.title
                        )
                        .disabled(model.admittedVersions == nil)
                    }
                }.buttonStyle(.edith(.borderless))
            }
            if model.admittedVersions != nil {
                if model.providers.isEmpty, model.loading { LoadingIndicator() }
                content
            }
            if let error = model.error {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry") { model.requestRefresh() }.buttonStyle(.edith(.secondary))
            }
        }
        .padding(UIScale.pt(presentation.padding))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation.cornerRadius))
        )
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Double.self) {
            $0.size.height
        } action: {
            measured($0)
        }
        .onChange(of: model.admittedVersions) { model.invalidate() }
    }

    @ViewBuilder private var content: some View {
        let metrics = projected.flatMap { provider in
            provider.snapshot.metrics.map { ScopedMetric(providerID: provider.id, metric: $0) }
        }
        if !metrics.isEmpty {
            LazyVGrid(
                columns: tile.metricGrid(minimum: tile.dense ? 72 : 88), alignment: .leading,
                spacing: UIScale.pt(10)
            ) {
                ForEach(metrics) { value in
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(value.metric.value).font(.edithText(tile.dense ? .headline : .title3))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(value.metric.title).font(.edithText(.caption)).foregroundStyle(
                            .secondary
                        ).lineLimit(2)
                        if tile.shows("progress"), let fraction = value.metric.fraction {
                            progressBar(fraction)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if tile.showDetails, tile.shows("items") {
            ForEach(Array(rows.prefix(tile.itemLimit))) { scoped in
                let row = scoped.row
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    HStack(alignment: .top, spacing: UIScale.pt(8)) {
                        Image(systemName: row.icon).foregroundStyle(tile.highlightColor).frame(
                            width: UIScale.pt(16))
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(row.title).font(.edithText(.callout)).lineLimit(tile.dense ? 1 : 2)
                            if tile.shows("metadata"), !row.detail.isEmpty {
                                Text(row.detail).font(.edithText(.caption)).foregroundStyle(
                                    .secondary
                                ).lineLimit(tile.dense ? 1 : 3)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if tile.shows("status"), !row.value.isEmpty {
                            Text(row.value).font(.edithText(.caption)).foregroundStyle(.secondary)
                                .lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                    if tile.shows("progress"), let progress = row.progress { progressBar(progress) }
                    if tile.showActions {
                        SurfaceSnapshotContent(
                            tile: tile,
                            snapshot: .init(
                                providerID: scoped.providerID, sliders: row.sliders ?? []),
                            perform: {
                                model.requestAction(providerID: scoped.providerID, actionID: $0.id)
                            },
                            adjust: {
                                model.requestAction(
                                    providerID: scoped.providerID, actionID: $0.id, value: $1)
                            })
                        actions(row.actions, providerID: scoped.providerID)
                    }
                }.padding(.vertical, UIScale.pt(tile.dense ? 3 : 5))
            }
            if rows.count > tile.itemLimit {
                Text("\(rows.count - tile.itemLimit) more items").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(projected, id: \.id) { provider in
            if let message = provider.snapshot.message {
                Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            if tile.showActions { actions(provider.snapshot.actions, providerID: provider.id) }
            if tile.showDetails, tile.shows("updated"), let date = provider.snapshot.updatedAt {
                Text("Updated " + date.formatted(.dateTime.hour().minute())).font(
                    .edithText(.caption2)
                ).foregroundStyle(.secondary)
            }
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.secondary.opacity(0.2)).overlay(alignment: .leading) {
                Capsule().fill(tile.highlightColor).frame(width: geometry.size.width * fraction)
            }
        }.frame(height: UIScale.pt(5)).accessibilityElement()
            .accessibilityLabel("Progress").accessibilityValue(
                "\(Int((fraction * 100).rounded())) percent")
    }
    private func actions(_ values: [SurfaceAction], providerID: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(8)) {
                ForEach(values) { actionButton($0, providerID: providerID) }
            }
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(values) { actionButton($0, providerID: providerID) }
            }
        }.disabled(model.acting)
    }
    private func actionButton(_ action: SurfaceAction, providerID: String) -> some View {
        Button {
            model.requestAction(providerID: providerID, actionID: action.id)
        } label: {
            Label(action.title, systemImage: action.icon).font(.edithText(.caption))
        }.buttonStyle(.edith(.secondary))
    }
    private struct ScopedMetric: Identifiable {
        let providerID: String
        let metric: SurfaceMetric
        var id: String { providerID + "/" + metric.id }
    }
    private struct ScopedRow: Identifiable {
        let providerID: String
        let row: SurfaceDataRow
        var id: String { providerID + "/" + row.id }
    }
}
