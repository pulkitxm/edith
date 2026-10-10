import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct UsageHomeLimitsCard: View {
    let tile: SurfaceTile
    let scene: UsageUIPresentation
    @State private var snapshot: UsageCompactLimitsSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @State private var action: Task<Void, Never>?
    @State private var actionError: String?
    @Environment(\.surfacePresentation) private var presentation
    @Environment(\.surfaceFillHeight) private var fillHeight
    @Environment(\.automaticViewActionsEnabled) private var active

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
                            retry += 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh widget").accessibilityLabel("Refresh " + tile.displayTitle)
                        Button {
                            open()
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .help("Open " + tile.widget.title).accessibilityLabel(
                            "Open " + tile.widget.title)
                    }
                }.buttonStyle(.edith(.borderless))
            }
            if let snapshot {
                data(snapshot).presenterCover(scene.presenter.hides("Usage"))
            } else if load.isRunning {
                LoadingIndicator()
            } else if !active {
                Text("Automatic updates are paused.").font(.edithText(.caption)).foregroundStyle(
                    .secondary)
                Button("Load widget") { retry += 1 }.buttonStyle(.edith(.secondary))
            }
            if let error = actionError ?? load.errorMessage {
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
        .task(id: "\(active):\(tile):\(retry)") {
            guard active || retry > 0 else { return }
            repeat {
                let request = load.begin()
                do {
                    let next = try await scene.compactLimits()
                    guard !Task.isCancelled, load.isCurrent(request), !scene.stopping else {
                        return
                    }
                    snapshot = next; load.complete(request)
                } catch is CancellationError { load.cancel(request); return } catch {
                    if load.isCurrent(request) { load.fail(request, error: error) }
                }
                guard active else { return }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear {
            action?.cancel(); action = nil
        }
    }

    @ViewBuilder private func data(_ value: UsageCompactLimitsSnapshot) -> some View {
        let metrics = value.metrics.filter { tile.shows($0.id) }
        if !metrics.isEmpty {
            LazyVGrid(
                columns: tile.metricGrid(minimum: tile.dense ? 72 : 88), alignment: .leading,
                spacing: UIScale.pt(10)
            ) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(metric.value).font(.edithText(tile.dense ? .headline : .title3))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(metric.title).font(.edithText(.caption)).foregroundStyle(.secondary)
                            .lineLimit(2)
                        if tile.shows("progress"), let fraction = metric.fraction {
                            progressBar(fraction)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if tile.showDetails, tile.shows("items") {
            ForEach(Array(value.rows.filter { tile.shows($0.field) }.prefix(tile.itemLimit))) {
                row in
                let detail = row.details.filter { tile.shows($0.field) }.map(\.text).filter {
                    !$0.isEmpty
                }.joined(separator: " · ")
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    HStack(alignment: .top, spacing: UIScale.pt(8)) {
                        Image(systemName: row.icon).foregroundStyle(tile.highlightColor).frame(
                            width: UIScale.pt(16))
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(row.title).font(.edithText(.callout)).lineLimit(tile.dense ? 1 : 2)
                            if tile.shows("metadata"), !detail.isEmpty {
                                Text(detail).font(.edithText(.caption)).foregroundStyle(.secondary)
                                    .lineLimit(tile.dense ? 1 : 3)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if tile.shows("status"), !row.value.isEmpty {
                            Text(row.value).font(.edithText(.caption)).foregroundStyle(.secondary)
                                .lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                    if tile.shows("progress"), let progress = row.progress { progressBar(progress) }
                }.padding(.vertical, UIScale.pt(tile.dense ? 3 : 5))
            }
            if value.rows.count > tile.itemLimit {
                Text("\(value.rows.count - tile.itemLimit) more items").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        if let message = value.message {
            Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
        }
        if tile.showActions {
            Button {
                open()
            } label: {
                Label("Open Agent Usage", systemImage: "arrow.up.right").font(.edithText(.caption))
            }
            .buttonStyle(.edith(.secondary))
        }
        if tile.showDetails, tile.shows("updated") {
            Text("Updated " + value.updatedAt.formatted(.dateTime.hour().minute())).font(
                .edithText(.caption2)
            ).foregroundStyle(.secondary)
        }
    }
    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            Capsule().fill(Color.secondary.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule().fill(tile.highlightColor)
                        .frame(width: geometry.size.width * fraction)
                }
        }.frame(height: UIScale.pt(5))
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }

    private func open() {
        action?.cancel()
        action = Task {
            do { try await scene.open(); if !Task.isCancelled { actionError = nil } } catch {
                if !Task.isCancelled, !scene.stopping { actionError = error.localizedDescription }
            }
        }
    }
}
