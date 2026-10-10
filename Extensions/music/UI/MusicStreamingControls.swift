import SwiftUI
import EdithExtensionUI
import EdithExtensionSupport
struct EmbeddedMusicStreamingControls: View {
    @Environment(\.compactLayout) private var compact
    @State private var optionsPresented = false
    @State private var accounts = EmbeddedMusicAccounts.shared
    init(accounts: EmbeddedMusicAccounts? = nil) {
        _accounts = State(initialValue: accounts ?? .shared)
    }

    var body: some View {
        HStack(spacing: UIScale.pt(14)) {
            trackSummary
            if compact {
                transport
                Button {
                    optionsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: UIScale.pt(26), height: UIScale.pt(30))
                }
                .buttonStyle(.edith(.toolbar))
                .accessibilityLabel("Spotify playback options")
                .popover(isPresented: $optionsPresented) {
                    VStack(spacing: UIScale.pt(12)) {
                        positionSlider
                        playbackModes
                        volumeSlider
                    }
                    .padding(UIScale.pt(16))
                    .frame(width: PresentationMetrics.width(280))
                }
            } else {
                VStack(spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(12)) {
                        playbackModes; transport
                    }
                    positionSlider
                }.frame(width: UIScale.pt(280))
                Spacer(minLength: 0)
                Button {
                    accounts.spotify.library.showQueue()
                    accounts.spotify.library.navigate(to: .queue)
                    EmbeddedMusicRemote.shared.send(.openMusic)
                } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.edith(.toolbar)).accessibilityLabel("Open playback queue")
                volumeSlider
            }
        }
        .font(.edithText(.body))
        .disabled(!accounts.spotify.connected)
    }

    private var trackSummary: some View {
        HStack(spacing: UIScale.pt(10)) {
            EmbeddedMusicStreamingArtwork(url: accounts.spotify.artworkURL)
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(accounts.spotify.title.isEmpty ? "Nothing playing" : accounts.spotify.title)
                    .font(.edithText(.headline)).lineLimit(1).presenterBlur(
                        EmbeddedMusicPrivacyState.shared.hides(.music))
                Text(accounts.spotify.artist.isEmpty ? "Spotify" : accounts.spotify.artist)
                    .font(.edithText(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    .presenterBlur(EmbeddedMusicPrivacyState.shared.hides(.music))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackModes: some View {
        HStack(spacing: UIScale.pt(8)) {
            Button {
                accounts.spotify.library.setShuffle(!accounts.spotify.library.shuffle)
            } label: {
                Image(systemName: "shuffle").foregroundStyle(
                    accounts.spotify.library.shuffle ? Color.accentColor : .secondary)
            }.buttonStyle(.edith(.toolbar)).accessibilityLabel("Shuffle")
            Button {
                let modes = ["off", "context", "track"]
                let index = modes.firstIndex(of: accounts.spotify.library.repeatMode) ?? 0
                accounts.spotify.library.setRepeat(modes[(index + 1) % modes.count])
            } label: {
                Image(
                    systemName: accounts.spotify.library.repeatMode == "track"
                        ? "repeat.1" : "repeat"
                )
                .foregroundStyle(
                    accounts.spotify.library.repeatMode == "off" ? Color.secondary : .accentColor)
            }.buttonStyle(.edith(.toolbar)).accessibilityLabel(
                "Repeat: \(accounts.spotify.library.repeatMode)")
        }
    }

    private var transport: some View {
        HStack(spacing: UIScale.pt(14)) {
            control("backward.fill", label: "Previous track", action: "previous")
            control(
                accounts.spotify.playing ? "pause.fill" : "play.fill", label: "Play or pause",
                action: "toggle")
            control("forward.fill", label: "Next track", action: "next")
        }
    }

    private var positionSlider: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: UIScale.pt(2)) {
                Slider(
                    value: Binding(
                        get: {
                            accounts.spotify.duration > 0
                                ? accounts.spotify.elapsed / accounts.spotify.duration : 0
                        },
                        set: {
                            accounts.spotify.seek(
                                by: $0 * accounts.spotify.duration - accounts.spotify.elapsed)
                        }),
                    in: 0...1
                )
                .frame(width: UIScale.pt(compact ? 248 : 280))
                .disabled(accounts.spotify.duration <= 0)
                .accessibilityLabel("Spotify playback position")
                HStack {
                    Text(EmbeddedTrackMeta.timeLabel(accounts.spotify.elapsed))
                    Spacer()
                    Text(EmbeddedTrackMeta.timeLabel(accounts.spotify.duration))
                }
                .font(.edithText(.caption2)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var volumeSlider: some View {
        HStack(spacing: UIScale.pt(6)) {
            Image(systemName: "speaker.wave.2")
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { accounts.spotify.volume }, set: { accounts.spotify.setVolume($0) }),
                in: 0...1
            )
            .frame(width: UIScale.pt(80)).accessibilityLabel("Spotify volume")
        }
    }

    private func control(_ symbol: String, label: String, action: String) -> some View {
        Button {
            accounts.spotify.send(["action": action])
        } label: {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(14)))
                .frame(width: UIScale.pt(28), height: UIScale.pt(30))
        }
        .buttonStyle(.edith(.toolbar))
        .accessibilityLabel(label).help(label)
    }
}
