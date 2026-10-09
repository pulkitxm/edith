import AppKit
import SwiftUI

public struct SurfaceExtensionCard: View {
    let tile: SurfaceTile
    let active: Bool
    let open: (String) -> Void
    private let fixture: SurfaceExtensionSnapshot?
    @State private var snapshot: SurfaceExtensionSnapshot?
    @State private var load = ContentLoad()
    @State private var retry = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var actionError: String?
    @State private var acting = false
    @Environment(\.surfacePresentation) private var presentation
    @Environment(\.surfaceFillHeight) private var fillHeight

    public init(
        tile: SurfaceTile, active: Bool = true, fixture: SurfaceExtensionSnapshot? = nil,
        open: @escaping (String) -> Void
    ) {
        self.tile = tile; self.active = active; self.open = open; self.fixture = fixture
        _snapshot = State(initialValue: fixture)
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
                        .disabled(fixture != nil)
                        Button {
                            open(tile.widget.destination)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                        .help("Open " + tile.widget.title).accessibilityLabel(
                            "Open " + tile.widget.title
                        )
                        .disabled(fixture != nil)
                    }
                }.buttonStyle(.edith(.borderless))
            }
            if let value = fixture ?? snapshot {
                data(value).presenterCover(privacy)
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
        .task(
            id: SurfaceExtensionRefreshKey(
                active: active, request: SurfaceExtensionRequestKey(tile), retry: retry)
        ) {
            guard fixture == nil, active || retry > 0 else { return }
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
            ForEach(
                Array(value.rows.filter { tile.shows($0.field ?? "items") }.prefix(tile.itemLimit))
            ) { row in
                let detail =
                    ([row.detail] + row.details.filter { tile.shows($0.field) }.map(\.text)).filter
                { !$0.isEmpty }.joined(separator: " · ")
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    HStack(alignment: .top, spacing: UIScale.pt(8)) {
                        Image(systemName: row.icon).foregroundStyle(
                            tile.highlightColor
                        )
                        .frame(width: UIScale.pt(16))
                        VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                            Text(row.title).font(.edithText(.callout)).lineLimit(tile.dense ? 1 : 2)
                            if tile.shows("metadata"), !detail.isEmpty {
                                Text(detail).font(.edithText(.caption)).foregroundStyle(
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
                        progressBar(progress)
                    }
                    if tile.showActions, tile.shows("volume"), let volume = row.volume {
                        SurfaceAudioSlider(control: volume, title: row.title) {
                            perform(.audioVolume(volume.target, $0))
                        }.disabled(acting || fixture != nil)
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
    private func actions(_ items: [SurfaceRowAction]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: UIScale.pt(8)) { ForEach(items) { actionButton($0) } }
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                ForEach(items) { actionButton($0) }
            }
        }.disabled(acting || fixture != nil)
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
        case .limits, .codeStats: .usage
        case .machines: .fleet
        case .ability("attention"): .attention
        case .ability("companion"): .memory
        case .ability("seoAudit"): .siteAudit
        case .ability("system"), .ability("bifrost"): .runningApps
        case .ability("virtualCamera"): .camera
        case .ability("studio"), .media, .ability("downloads"), .ability("timeLapse"),
            .ability("audioMixer"):
            .studio
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
                case .audioVolume(let target, let volume):
                    let updated = try await SurfaceMediaClient.audio(
                        .volume, target: target, volume: volume)
                    await SurfaceExtensionClient.shared.invalidate(tile.widget)
                    snapshot = SurfaceMediaProjection.audio(updated, tile: tile)
                    return
                case .stopRecording(let sessionID):
                    _ = try await SurfaceMediaClient.recorder(.stop, sessionID: sessionID)
                    await SurfaceExtensionClient.shared.invalidate(tile.widget)
                }
                await refresh(force: true)
            } catch is CancellationError {} catch { actionError = error.localizedDescription }
        }
    }
}

private struct SurfaceAudioSlider: View {
    let control: SurfaceVolumeControl
    let title: String
    let commit: (Double) -> Void
    @State private var value: Double
    @State private var editing = false
    init(control: SurfaceVolumeControl, title: String, commit: @escaping (Double) -> Void) {
        self.control = control; self.title = title; self.commit = commit
        _value = State(initialValue: control.value)
    }
    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            Slider(value: $value, in: 0...1, step: 0.01) { isEditing in
                editing = isEditing
                if !isEditing, abs(value - control.value) > 0.0001 { commit(value) }
            }.accessibilityLabel("Volume for " + title)
            Text("\(Int((value * 100).rounded()))%")
                .font(.edithText(.caption)).monospacedDigit().frame(width: UIScale.pt(40))
        }.onChange(of: control.value) { _, next in if !editing { value = next } }
    }
}
