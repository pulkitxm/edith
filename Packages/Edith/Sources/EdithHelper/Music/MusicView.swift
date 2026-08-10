import EdithKit
import SwiftUI

struct MusicView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        VStack(spacing: 10) {
            if player.tracks.isEmpty {
                Text("No playable files in \(Repo.musicDir.path)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(player.tracks) { track in
                            TrackRow(track: track)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(player.tracks.count) * 48 - 2, 520))
            }
        }
        .onAppear { player.rescan() }
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var player: MusicPlayer
    let track: Track
    @State private var artwork: NSImage?
    @State private var duration: String?
    @State private var hovering = false
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"

    private var theme: Color { themeColor(themeName) }
    private var isCurrent: Bool { player.current == track }

    var body: some View {
        Button {
            player.toggle(track)
        } label: {
            HStack(spacing: 10) {
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
                                startPoint: .top, endPoint: .bottom
                            )
                            Image(systemName: "music.note")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7))

                Text(track.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? theme : .primary)
                    .presenterBlur(presenterState.active && presenterBlurMusic)

                Spacer()

                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme)
                }

                if let duration {
                    Text(duration)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isCurrent
                ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .onHover { hovering = $0 }
        .pointerCursor()
        .task {
            artwork = await player.artwork(for: track)
            duration = await player.durationLabel(for: track)
        }
    }
}
