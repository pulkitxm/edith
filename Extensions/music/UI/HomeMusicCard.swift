import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

struct EmbeddedHomeMusicCard: View {
    @Environment(\.surfacePresentation) private var presentation
    let dark: Bool
    @State private var remote: EmbeddedMusicRemote
    @State private var accounts: EmbeddedMusicAccounts
    private let open: @MainActor () -> Void

    init(
        dark: Bool, remote: EmbeddedMusicRemote = .shared,
        accounts: EmbeddedMusicAccounts = .shared,
        open: @escaping @MainActor () -> Void = { EmbeddedMusicRemote.shared.send(.openMusic) }
    ) {
        self.dark = dark
        _remote = State(initialValue: remote)
        _accounts = State(initialValue: accounts)
        self.open = open
    }
    @Environment(\.windowVisible) private var visible

    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.automaticViewActionsEnabled) private var automaticActionsEnabled

    private var theme: Color { themeColor(themeName) }
    private var blur: Bool { EmbeddedMusicPrivacyState.shared.hides(.music) }

    private var upNext: [EmbeddedTrack] {
        remote.tracks.filter { $0.relativePath != remote.currentFile }.prefix(
            presentation?.tile.itemLimit ?? 4
        )
        .map { $0 }
    }

    var body: some View {
        PageCard(
            title: "Music",
            note: accounts.selected == .local
                ? (remote.tracks.isEmpty ? "" : "\(remote.tracks.count) tracks")
                : accounts.selected.title
        ) {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                if accounts.selected == .local {
                    if let track = remote.current {
                        nowPlaying(track)
                        Divider().opacity(0.4)
                    }
                    if remote.tracks.isEmpty {
                        Text("Drop audio files into your music folder to play them here.")
                            .font(.system(size: UIScale.pt(12.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(maxWidth: .infinity, minHeight: UIScale.pt(70))
                    } else if presentation?.tile.shows("queue") != false {
                        ForEach(upNext) { track in
                            trackRow(track)
                        }
                    }
                } else {
                    streaming
                }
                EmbeddedHomeMusicJumpLink(dark: dark, open: open)
            }
        }
        .onAppear {
            if automaticActionsEnabled { remote.start() }
        }
    }

    @ViewBuilder private var streaming: some View {
        if accounts.selected == .spotify, accounts.spotify.connected {
            HStack(spacing: UIScale.pt(10)) {
                if presentation?.tile.shows("artwork") != false {
                    EmbeddedMusicStreamingArtwork(url: accounts.spotify.artworkURL)
                }
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(
                        accounts.spotify.title.isEmpty ? "Nothing playing" : accounts.spotify.title
                    )
                    .font(.edithText(.headline)).lineLimit(1).presenterBlur(
                        EmbeddedMusicPrivacyState.shared.hides(.music))
                    if presentation?.tile.shows("artist") != false {
                        Text(accounts.spotify.artist.isEmpty ? "Spotify" : accounts.spotify.artist)
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                            .lineLimit(1).presenterBlur(
                                EmbeddedMusicPrivacyState.shared.hides(.music))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if presentation?.tile.showActions != false {
                    Button {
                        accounts.spotify.send(["action": "toggle"])
                    } label: {
                        Image(systemName: accounts.spotify.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: UIScale.pt(15))).foregroundStyle(theme)
                    }
                    .buttonStyle(.edith(.toolbar))
                    .accessibilityLabel("Play or pause Spotify")
                    Button {
                        accounts.spotify.send(["action": "next"])
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: UIScale.pt(12))).foregroundStyle(theme)
                    }
                    .buttonStyle(.edith(.toolbar))
                    .accessibilityLabel("Next Spotify track")
                }
            }
        } else {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: accounts.selected.symbol)
                    .font(.edithText(.title2)).foregroundStyle(theme)
                    .frame(width: UIScale.pt(40), height: UIScale.pt(40))
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(accounts.selected.title).font(.edithText(.headline))
                    Text(
                        accounts.youtubeConnected && accounts.selected == .youtubeMusic
                            ? "Your player is ready in Music."
                            : "Connect your account in Music to start listening."
                    )
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var elapsedText: some View {
        Text(
            "\(EmbeddedTrackMeta.timeLabel(remote.elapsed)) / \(EmbeddedTrackMeta.timeLabel(remote.duration))"
        )
        .font(DashSkin.mono(9.5))
        .foregroundStyle(DashSkin.inkFaint(dark))
    }

    private func nowPlaying(_ track: EmbeddedTrack) -> some View {
        HStack(spacing: UIScale.pt(10)) {
            if presentation?.tile.shows("artwork") != false {
                EmbeddedHomeArtworkThumb(track: track, size: 40)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(track.title)
                    .font(.system(size: UIScale.pt(13), weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(DashSkin.ink(dark))
                    .presenterBlur(blur)
                if presentation?.tile.shows("progress") != false {
                    if remote.isPlaying, visible, automaticActionsEnabled {
                        TimelineView(.periodic(from: EmbeddedMusicTick.epoch, by: 1)) { _ in
                            elapsedText
                        }
                    } else {
                        elapsedText
                    }
                }
            }
            EmbeddedPlaybackWave(
                playing: remote.isPlaying, color: theme.opacity(0.9), maxHeight: UIScale.pt(14))
            Spacer(minLength: 6)
            if presentation?.tile.showActions != false {
                Button {
                    remote.playPause()
                } label: {
                    Image(systemName: remote.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: UIScale.pt(15)))
                        .foregroundStyle(theme)
                }
                .buttonStyle(.edith(.toolbar))
                .accessibilityLabel("Play or pause music")
                Button {
                    remote.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(theme)
                }
                .buttonStyle(.edith(.toolbar))
                .accessibilityLabel("Next music track")
            }
        }
    }

    private func trackRow(_ track: EmbeddedTrack) -> some View {
        Button {
            remote.toggle(track)
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                if presentation?.tile.shows("artwork") != false {
                    EmbeddedHomeArtworkThumb(track: track, size: 26)
                }
                Text(track.title)
                    .font(.system(size: UIScale.pt(12)))
                    .lineLimit(1)
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .presenterBlur(blur)
                Spacer(minLength: 6)
                if presentation?.tile.showActions != false {
                    Image(systemName: "play.fill").font(.system(size: UIScale.pt(9)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .allowsHitTesting(presentation?.tile.showActions != false)
    }
}

private struct EmbeddedHomeArtworkThumb: View {
    let track: EmbeddedTrack
    var size: CGFloat = 36
    @State private var artwork: NSImage?

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(hue: track.hue, saturation: 0.55, brightness: 0.45),
                            Color(hue: track.hue, saturation: 0.6, brightness: 0.22),
                        ],
                        startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .presenterCover(EmbeddedMusicPrivacyState.shared.hides(.music))
        .pageTask(id: track.id) {
            let loaded = await EmbeddedTrackMeta.artwork(for: track)
            guard !Task.isCancelled else { return }
            artwork = loaded
        }
    }
}

struct EmbeddedMusicHomeScene: View {
    let tile: SurfaceTile
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        EmbeddedHomeMusicCard(dark: scheme == .dark)
            .environment(
                \.surfacePresentation,
                SurfacePresentation(
                    tile: tile,
                    layout: SurfaceHostContext.current?.layout(.home)
                        ?? SurfaceLayout.standard(.home)))
    }
}

private struct EmbeddedHomeMusicJumpLink: View {
    @Environment(\.surfacePresentation) private var presentation
    let dark: Bool
    let open: @MainActor () -> Void

    var body: some View {
        if presentation?.tile.showActions != false {
            Button(action: open) {
                HStack(spacing: UIScale.pt(4)) {
                    Text("Open Music")
                    Image(systemName: "arrow.right")
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                }
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.accentDeep(dark))
            }
            .buttonStyle(.edith(.borderless))
            .padding(.top, UIScale.pt(10))
        }
    }
}
