import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

struct EmbeddedMusicNotchRoute: Equatable {
    enum Section: String, CaseIterable {
        case card = "music"
        case leading = "music.glance.leading"
        case trailing = "music.glance.trailing"
        case header = "music.header"
    }
    let section: Section
    let request: SurfaceSnapshotRequest

    init?(context: NSDictionary) {
        guard context["location"] as? String == "notch",
            context["target"] as? String == "notch",
            let value = context["section"] as? String, let section = Section(rawValue: value),
            let data = context["tile"] as? Data, data.count <= 65_536,
            let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
            tile.widget == .music,
            (try? SurfaceSnapshotRequest(target: .notch, tile: tile).encoded(providerID: "music"))
                != nil
        else { return nil }
        self.section = section
        request = SurfaceSnapshotRequest(target: .notch, tile: tile)
    }
}

struct EmbeddedNotchNowPlaying: Equatable {
    enum Source: Equatable {
        case local
        case external(String)
    }
    var source: Source
    var title: String
    var artist: String
    var isPlaying: Bool
}

@MainActor @Observable final class EmbeddedMusicNotchModel {
    let request: SurfaceSnapshotRequest
    private let expectedVersion: String?
    private let presentationID: UUID?
    private(set) var state: EmbeddedMusicNotchState?
    private(set) var nowPlayingControlError: String?
    private(set) var closed = false
    @ObservationIgnored private let invoke: (String, Data) async throws -> Data
    @ObservationIgnored private var reading: Task<EmbeddedMusicNotchState, Error>?
    @ObservationIgnored private var actions: [UUID: Task<Void, Never>] = [:]
    private var revision: UInt64 = 0
    private var selectedSource: String?

    init(request: SurfaceSnapshotRequest, remote: EmbeddedMusicRemote = .shared) {
        self.presentationID = nil; self.expectedVersion = nil; self.request = request;
        self.invoke = { operation, payload in
            try await remote.dataRequest(operation, payload: payload)
        }
    }

    init(
        request: SurfaceSnapshotRequest, expectedVersion: String? = nil,
        presentationID: UUID? = nil,
        invoke: @escaping (String, Data) async throws -> Data
    ) {
        self.presentationID = presentationID; self.expectedVersion = expectedVersion;
        self.request = request; self.invoke = invoke
    }

    var row: SurfaceDataRow? {
        state?.snapshot.rows.first { $0.sourceID == selectedSource && $0.field == nil }
    }
    var playback: EmbeddedMusicNotchPlayback? { state?.playback.first { $0.rowID == row?.id } }
    var hidden: Bool { state?.snapshot.message == "Hidden while presenting." }
    var nowPlaying: EmbeddedNotchNowPlaying? {
        guard let row, let playback else { return nil }
        return .init(
            source: row.sourceID == "local" ? .local : .external(playback.sourceName),
            title: row.title, artist: row.detail, isPlaying: playback.playing)
    }
    var nowPlayingArtwork: NSImage? {
        image(row?.thumbnail ?? playback?.appIcon)
    }
    var nowPlayingAppIcon: NSImage? { image(playback?.appIcon) }
    var nowPlayingShuffle: Bool? { playback?.shuffle }
    var nowPlayingRepeat: Bool? { playback?.repeating }
    var nowPlayingVolume: Double? { slider("volume")?.value }
    var nowPlayingDuration: Double { playback?.duration ?? 0 }
    var nowPlayingSeekable: Bool { slider("progress") != nil }
    func nowPlayingProgress() -> Double { row?.progress ?? 0 }
    private func image(_ thumbnail: SurfaceThumbnail?) -> NSImage? {
        guard let image = try? thumbnail?.decodedImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    func refresh() async {
        guard !closed, reading == nil else { return }
        let token = revision
        let task = Task {
            let payload = try request.encoded(providerID: "music")
            return try EmbeddedMusicNotchState.decode(await invoke("music.notch.snapshot", payload))
        }
        reading = task
        defer { if revision == token { reading = nil } }
        do {
            let value = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard !closed, revision == token else { return }
            guard expectedVersion == nil || value.version == expectedVersion else {
                state = nil; selectedSource = nil
                throw ExtensionPeerError.invalidRequest
            }
            let candidates = value.snapshot.rows.filter { row in
                value.playback.contains { $0.rowID == row.id }
            }
            let local = candidates.first { $0.sourceID == "local" }
            let playing = candidates.first { row in
                value.playback.contains { $0.rowID == row.id && $0.playing }
            }
            if let local, value.playback.contains(where: { $0.rowID == local.id && $0.playing }) {
                selectedSource = "local"
            } else if let playing {
                selectedSource = playing.sourceID
            } else if selectedSource != "local" {
                selectedSource = candidates.first { $0.sourceID != "local" }?.sourceID
            } else {
                selectedSource = local?.sourceID
            }
            state = value; nowPlayingControlError = nil
        } catch {
            if !closed, revision == token, !Task.isCancelled, !task.isCancelled {
                nowPlayingControlError = error.localizedDescription
            }
        }
    }
    func suspend() {
        revision &+= 1; reading?.cancel(); reading = nil
        for task in actions.values { task.cancel() }
        actions.removeAll()
    }
    func shutdown() { suspend(); closed = true; state = nil; selectedSource = nil }
    private func slider(_ field: String) -> SurfaceSlider? {
        row?.sliders?.first { $0.field == field }
    }
    private func action(_ kind: String) -> SurfaceAction? {
        ((row?.actions ?? []) + (state?.snapshot.actions ?? [])).first {
            $0.id.hasPrefix(kind + ":")
                && $0.id.hasSuffix(":" + (row?.id.components(separatedBy: ":").last ?? ""))
        }
    }
    func perform(_ kind: String, value: Double? = nil) {
        guard !closed, request.tile.showActions, !hidden,
            let identifier = value == nil
                ? action(kind)?.id : slider(kind == "seek" ? "progress" : kind)?.id
        else { return }
        let token = revision
        let id = UUID()
        actions[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.actions[id] = nil }
            do {
                let action = SurfaceActionRequest(
                    snapshot: request, actionID: identifier, value: value)
                if let presentationID {
                    let payload = try EmbeddedMusicNotchActionRequest(
                        presentationID: presentationID, action: action
                    ).encoded()
                    _ = try await invoke("music.notch.perform", payload)
                } else {
                    _ = try await invoke("surface.perform", action.encoded(providerID: "music"))
                }
                try Task.checkCancellation()
                guard !closed, token == revision else { return }
                await refresh()
            } catch {
                if !Task.isCancelled, !closed, token == revision {
                    nowPlayingControlError = error.localizedDescription
                }
            }
        }
    }
    func openNowPlayingLocation() { perform("open") }
    func openNowPlayingApp() { perform("openPlayer") }
    func nowPlayingPrevious() { perform("previous") }
    func nowPlayingNext() { perform("next") }
    func nowPlayingPlayPause() { perform("toggle") }
    func setNowPlayingShuffle(_ value: Bool) { perform("shuffle") }
    func setNowPlayingRepeat(_ value: Bool) { perform("repeat") }
    func setNowPlayingVolume(_ value: Double) { perform("volume", value: value) }
    func nowPlayingSeek(_ value: Double) { perform("seek", value: value) }
    func skipNowPlaying(_ seconds: Double) { perform(seconds < 0 ? "backward" : "forward") }
    func retryNowPlayingControls() {
        guard !closed else { return }
        let id = UUID()
        actions[id] = Task { [weak self] in
            await self?.refresh(); self?.actions[id] = nil
        }
    }
}

struct EmbeddedMusicNotchScene: View {
    let route: EmbeddedMusicNotchRoute
    @State var model: EmbeddedMusicNotchModel
    @Environment(\.surfacePresentation) private var presentation

    var body: some View {
        Group {
            switch route.section {
            case .card:
                if let track = model.nowPlaying {
                    EmbeddedNotchNowPlayingCard(
                        controller: model, track: track, tile: route.request.tile)
                } else {
                    emptyCard
                }
            case .leading: glance(leading: true)
            case .trailing: glance(leading: false)
            case .header:
                HStack(spacing: 4) {
                    if let icon = model.nowPlayingAppIcon {
                        Button {
                            model.openNowPlayingApp()
                        } label: {
                            Image(nsImage: icon).resizable().scaledToFit().frame(
                                width: 24, height: 24)
                        }.buttonStyle(.edith(.borderless)).help("Open the current music player")
                            .padding(.trailing, 6)
                            .disabled(!route.request.tile.showActions || model.hidden)
                    }
                }
            }
        }
        .environment(
            \.surfacePresentation,
            SurfacePresentation(tile: route.request.tile, layout: SurfaceLayout.standard(.notch))
        )
        .pageTask { await model.refresh() }
        .pageRefresh(interval: { .milliseconds(500) }) { await model.refresh() }
        .onDisappear { model.suspend() }
    }
    @ViewBuilder private func glance(leading: Bool) -> some View {
        if let track = model.nowPlaying {
            Button {
                if leading { model.openNowPlayingLocation() } else { model.nowPlayingPlayPause() }
            } label: {
                HStack(spacing: 5) {
                    if leading, let artwork = model.nowPlayingArtwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).presenterCover(
                                model.hidden)
                    } else {
                        EmbeddedPlaybackWave(
                            playing: track.isPlaying, color: .white.opacity(0.85), barCount: 4
                        ).frame(width: 20)
                    }
                }.foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.edith(.borderless)).help(track.title)
                .accessibilityLabel(track.title + ", " + (track.isPlaying ? "Playing" : "Paused"))
                .disabled(!route.request.tile.showActions || model.hidden)
        } else {
            Color.clear
        }
    }
    private var emptyCard: some View {
        VStack(spacing: 5) {
            Image(systemName: "music.note").font(.system(size: 15)).foregroundStyle(
                .white.opacity(0.28))
            if let error = model.nowPlayingControlError {
                Text(error).font(.edithText(.caption)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(4)
                if route.request.tile.showActions {
                    Button("Retry playback controls") { model.retryNowPlayingControls() }
                        .font(.edithText(.caption)).buttonStyle(.edith(.borderless))
                }
            } else {
                Text(model.state?.snapshot.message ?? "Nothing playing").font(.edithText(.caption))
                    .foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmbeddedNotchNowPlayingCard: View {
    var controller: EmbeddedMusicNotchModel
    let track: EmbeddedNotchNowPlaying
    let tile: SurfaceTile
    @Environment(\.surfacePresentation) private var presentation

    init(controller: EmbeddedMusicNotchModel, track: EmbeddedNotchNowPlaying, tile: SurfaceTile) {
        self.controller = controller
        self.track = track
        self.tile = tile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tile.showTitle {
                HStack {
                    Label(tile.displayTitle, systemImage: "music.note")
                        .font(.edithText(.caption).weight(.semibold))
                    Spacer()
                    if let icon = controller.nowPlayingAppIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                        Text(sourceName).font(.edithText(.caption2)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                if tile.shows("artwork") { artwork.disabled(!tile.showActions) }
                Button {
                    controller.openNowPlayingLocation()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.edithText(.headline)).foregroundStyle(.white)
                            .lineLimit(2).presenterBlur(controller.hidden)
                        if tile.showDetails, tile.shows("artist") {
                            Text(sourceLabel).font(.edithText(.caption)).foregroundStyle(.secondary)
                                .lineLimit(2).presenterBlur(
                                    controller.hidden)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.edith(.borderless)).disabled(!tile.showActions)
                    .help(isLocal ? "Show this track in Music" : "Open the app playing this")
            }
            if tile.showDetails, tile.shows("progress"), controller.nowPlayingSeekable {
                NotchSeekBar(
                    controller: controller,
                    showsSkip: tile.showActions && tile.shows("seekControls")
                ).allowsHitTesting(tile.showActions)
            }
            if tile.showActions {
                HStack(spacing: 8) {
                    if tile.shows("shuffle"), let enabled = controller.nowPlayingShuffle {
                        control(
                            "shuffle", 14, label: enabled ? "Turn shuffle off" : "Turn shuffle on",
                            selected: enabled
                        ) {
                            controller.setNowPlayingShuffle(!enabled)
                        }
                    }
                    control("backward.fill", 15, label: "Previous track") {
                        controller.nowPlayingPrevious()
                    }
                    control(
                        track.isPlaying ? "pause.fill" : "play.fill", 20,
                        label: track.isPlaying ? "Pause" : "Play"
                    ) {
                        controller.nowPlayingPlayPause()
                    }
                    control("forward.fill", 15, label: "Next track") { controller.nowPlayingNext() }
                    if tile.shows("repeat"), let enabled = controller.nowPlayingRepeat {
                        control(
                            "repeat", 14, label: enabled ? "Turn repeat off" : "Turn repeat on",
                            selected: enabled
                        ) {
                            controller.setNowPlayingRepeat(!enabled)
                        }
                    }
                }
                if tile.shows("volume"), controller.nowPlayingVolume != nil {
                    NotchVolumeControl(controller: controller)
                }
                if let error = controller.nowPlayingControlError {
                    Text(error).font(.edithText(.caption2)).foregroundStyle(.secondary).lineLimit(3)
                    Button("Retry playback controls") { controller.retryNowPlayingControls() }
                        .font(.edithText(.caption)).buttonStyle(.edith(.borderless))
                }
            }
        }
        .padding(presentation?.padding ?? tile.paddingOverride ?? 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            .white.opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: presentation?.cornerRadius ?? tile.cornerOverride ?? 12))
    }

    private var sourceName: String {
        switch track.source {
        case .local: "Music"
        case .external(let name): name
        }
    }

    private var isLocal: Bool {
        if case .local = track.source { return true }
        return false
    }

    private var sourceLabel: String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        switch track.source {
        case .local: parts.append("Music")
        case .external(let name): parts.append(name)
        }
        return parts.joined(separator: " · ")
    }

    private var artwork: some View {
        Button {
            controller.openNowPlayingApp()
        } label: {
            Group {
                if let image = controller.nowPlayingArtwork {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .presenterCover(controller.hidden)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.08))
                }
            }
            .frame(width: tile.dense ? 48 : 56, height: tile.dense ? 48 : 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
        }
        .buttonStyle(.edith(.borderless))
        .help("Open player")
    }

    private func control(
        _ name: String, _ size: CGFloat, label: String,
        selected: Bool = false, _ action: @escaping () -> Void
    )
        -> some View
    {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(selected ? tile.highlightColor : .white)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(
                    .white.opacity(selected ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless)).help(label).accessibilityLabel(label)
    }
}

private struct NotchSeekBar: View {
    var controller: EmbeddedMusicNotchModel
    var showsSkip: Bool
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: EmbeddedMusicTick.epoch, by: 0.5)) { _ in
            VStack(spacing: 4) {
                Slider(
                    value: Binding(
                        get: { dragFraction ?? controller.nowPlayingProgress() },
                        set: { dragFraction = $0 }), in: 0...1,
                    onEditingChanged: { editing in
                        if !editing, let fraction = dragFraction {
                            controller.nowPlayingSeek(fraction); dragFraction = nil
                        }
                    }
                )
                .controlSize(.small).tint(.white).accessibilityLabel("Playback position")
                HStack {
                    Text(
                        clock(
                            (dragFraction ?? controller.nowPlayingProgress())
                                * controller.nowPlayingDuration))
                    Spacer(minLength: 0)
                    if showsSkip {
                        Button {
                            controller.skipNowPlaying(-15)
                        } label: {
                            Image(systemName: "gobackward.15").font(.system(size: 13)).frame(
                                width: 26, height: 20)
                        }
                        .help("Back 15 seconds").accessibilityLabel("Back 15 seconds")
                        Button {
                            controller.skipNowPlaying(15)
                        } label: {
                            Image(systemName: "goforward.15").font(.system(size: 13)).frame(
                                width: 26, height: 20)
                        }
                        .help("Forward 15 seconds").accessibilityLabel("Forward 15 seconds")
                        Spacer(minLength: 0)
                    }
                    Text(clock(controller.nowPlayingDuration))
                }.font(.edithText(.caption2)).monospacedDigit().foregroundStyle(.secondary)
                    .buttonStyle(.edith(.borderless))
            }
        }
        .onChange(of: controller.nowPlaying?.title) { _, _ in dragFraction = nil }
    }

    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct NotchVolumeControl: View {
    var controller: EmbeddedMusicNotchModel
    @State private var requested: Double?
    @State private var savedVolume = 0.7

    var body: some View {
        let value = requested ?? controller.nowPlayingVolume ?? 0
        HStack(spacing: 8) {
            Button {
                if value > 0 { savedVolume = value }
                controller.setNowPlayingVolume(value == 0 ? savedVolume : 0)
            } label: {
                Image(systemName: value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 22, height: 24)
            }.buttonStyle(.edith(.borderless)).help(value == 0 ? "Unmute" : "Mute")
                .accessibilityLabel(value == 0 ? "Unmute" : "Mute")
            Slider(
                value: Binding(get: { value }, set: { requested = $0 }), in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let volume = requested {
                        controller.setNowPlayingVolume(volume); requested = nil
                    }
                }
            ).controlSize(.small).tint(.white).accessibilityLabel("Player volume")
            Text("\(Int(value * 100))%")
                .font(.edithText(.caption2)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .onChange(of: controller.nowPlaying?.source) { _, _ in
            requested = nil; savedVolume = 0.7
        }
    }
}
