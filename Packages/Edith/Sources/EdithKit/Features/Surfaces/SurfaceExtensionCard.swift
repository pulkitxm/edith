import AppKit
import SwiftUI

public struct SurfaceExtensionCard: View {
    let tile: SurfaceTile
    let active: Bool
    let open: (String) -> Void
    @State private var snapshot: SurfaceExtensionSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var actionError: String?
    @State private var acting = false
    @Environment(\.surfacePresentation) private var presentation

    public init(tile: SurfaceTile, active: Bool = true, open: @escaping (String) -> Void) {
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
                        .help("Refresh widget").accessibilityLabel("Refresh " + tile.displayTitle)
                        Button {
                            open(tile.widget.destination)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .help("Open " + tile.widget.title).accessibilityLabel(
                            "Open " + tile.widget.title)
                    }
                }.buttonStyle(.edith(.borderless))
            }
            if let snapshot {
                data(snapshot).presenterCover(privacy)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: UIScale.pt(presentation?.cornerRadius ?? 12))
        )
        .task(
            id: SurfaceExtensionRefreshKey(
                active: active, request: SurfaceExtensionRequestKey(tile), retry: retry)
        ) {
            guard active || retry > 0 else { return }
            var force = retry > 0
            repeat {
                await refresh(force: force)
                force = false
                guard active else { return }
                do {
                    try await Task.sleep(
                        for: .seconds(SurfaceExtensionClient.interval(tile.widget)))
                } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear {
            actionTask?.cancel(); actionTask = nil
        }
    }
    @ViewBuilder private func data(_ value: SurfaceExtensionSnapshot) -> some View {
        let metrics = value.metrics.filter { tile.shows($0.id) }
        if !metrics.isEmpty {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: UIScale.pt(tile.dense ? 76 : 100)),
                        spacing: UIScale.pt(12))
                ], alignment: .leading, spacing: UIScale.pt(10)
            ) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(metric.value).font(.edithText(tile.dense ? .headline : .title3))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text(metric.title).font(.edithText(.caption)).foregroundStyle(.secondary)
                            .lineLimit(2)
                        if tile.shows("progress"), let fraction = metric.fraction {
                            ProgressView(value: fraction).tint(
                                tile.accent ? .accentColor : .secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        if tile.showDetails, tile.shows("items") {
            ForEach(Array(value.rows.prefix(tile.itemLimit))) { row in
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    HStack(alignment: .top, spacing: UIScale.pt(8)) {
                        Image(systemName: row.icon).foregroundStyle(
                            tile.accent ? Color.accentColor : .secondary
                        )
                        .frame(width: UIScale.pt(16))
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
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if tile.shows("progress"), let progress = row.progress {
                        ProgressView(value: progress).tint(tile.accent ? .accentColor : .secondary)
                    }
                    if tile.showActions, !row.actions.isEmpty { actions(row.actions) }
                }
                .padding(.vertical, UIScale.pt(tile.dense ? 3 : 5))
            }
            if value.rows.count > tile.itemLimit {
                Text("\(value.rows.count - tile.itemLimit) more items").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        if let message = value.message {
            Text(message).font(.edithText(.caption)).foregroundStyle(.secondary)
        }
        if tile.showActions, !value.actions.isEmpty { actions(value.actions) }
        if tile.showDetails, tile.shows("updated"), let date = value.updatedAt {
            Text("Updated " + date.formatted(.dateTime.hour().minute())).font(.edithText(.caption2))
                .foregroundStyle(.secondary)
        }
    }
    private func actions(_ items: [SurfaceRowAction]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(8)) { ForEach(items) { actionButton($0) } }
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(items) { actionButton($0) }
            }
        }.disabled(acting)
    }
    private func actionButton(_ item: SurfaceRowAction) -> some View {
        Button {
            perform(item.action)
        } label: {
            Label(item.title, systemImage: item.icon).font(.edithText(.caption))
        }.buttonStyle(.edith(.secondary))
    }
    private var privacy: PresenterPrivacy {
        switch tile.widget {
        case .machines: .fleet
        case .ability("attention"): .attention
        case .ability("companion"): .memory
        case .ability("seoAudit"): .siteAudit
        case .ability("system"), .ability("bifrost"): .runningApps
        case .ability("virtualCamera"): .camera
        case .ability("studio"), .media, .ability("downloads"): .studio
        default: .shelf
        }
    }
    private func refresh(force: Bool) async {
        let request = load.begin()
        defer { if Task.isCancelled { load.cancel(request) } }
        do {
            let next = try await SurfaceExtensionClient.shared.snapshot(tile, force: force)
            guard !Task.isCancelled, load.isCurrent(request) else { return }
            snapshot = next
            load.complete(request)
        } catch is CancellationError { load.cancel(request) } catch {
            if load.isCurrent(request) { load.fail(request, error: error) }
        }
    }
    private func perform(_ action: SurfaceExtensionAction) {
        actionTask?.cancel()
        acting = true
        actionError = nil
        actionTask = Task { @MainActor in
            defer { acting = false }
            do {
                switch action {
                case .navigate(let section): open(section)
                case .toggle(let key):
                    let current = SharedDefaults.store.bool(forKey: key)
                    if key == AppStorageKeys.Presenter.mode {
                        _ = PresenterRuntimeOperationExecution.perform(current ? .stop : .start)
                    } else {
                        try ConfigurationExecutor.application.set(.bool(!current), forKey: key)
                    }
                case .pickColor: IPC.post(IPC.Name.requestColorPick)
                case .pickEmoji: _ = try EmojiOperationExecution.perform(.pick)
                case .launchBifrost: IPC.post(IPC.Name.requestBifrostPanel)
                case .cleanKeys: AppRuntimeCenter().request(.cleanKeys)
                case .muteMicrophone: IPC.post(IPC.Name.requestMicrophoneMute)
                case .retryDownload(let id):
                    _ = try await AgentDownloadClient().mutateAsync(.retry(id: id, all: false))
                case .cancelDownload(let id):
                    _ = try await AgentDownloadClient().mutateAsync(
                        .cancel(id: id, includeQueued: true, reason: "Cancelled from widget"))
                case .copyClipboard(let id):
                    let payload = try await AgentClipboardClient().copy(id: id)
                    ClipboardRepository.copyToPasteboard(payload)
                case .pinClipboard(let id, let pinned):
                    _ = try await AgentClipboardClient().mutate(
                        .init(pinned ? .pin : .unpin, ids: [id]))
                case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
                case .openURL(let url):
                    guard
                        url.isFileURL || ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    NSWorkspace.shared.open(url)
                }
                await refresh(force: true)
            } catch is CancellationError {} catch { actionError = error.localizedDescription }
        }
    }
}
