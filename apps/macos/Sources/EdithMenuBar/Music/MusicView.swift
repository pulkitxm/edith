import EdithKit
import SwiftUI

struct MusicView: View {
    @EnvironmentObject private var player: MusicPlayer
    @ObservedObject private var mini = MiniPanel.shared
    @State private var dragFraction: Double?
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenter = false
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"

    private var theme: Color { themeColor(themeName) }
    private var blurMusic: Bool { presenter && presenterBlurMusic }

    private var scrubberRow: some View {
        HStack(spacing: 10) {
            Text(timeLabel(player.elapsed))
                .frame(width: 40, alignment: .leading)
            scrubber
            Text(timeLabel(player.trackDuration))
                .frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

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
                nowPlayingBar
            }
        }
        .onAppear { player.rescan() }
    }

    private var nowPlayingBar: some View {
        VStack(spacing: 10) {
            if player.current != nil {
                if mini.panelOpen {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in scrubberRow }
                } else {
                    scrubberRow
                }
            }
            HStack(spacing: 12) {
                if let track = player.current {
                    ArtworkThumb(track: track, player: player, size: 40)
                }
                Text(player.current?.title ?? "Not playing")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .foregroundStyle(player.current == nil ? .secondary : .primary)
                    .presenterBlur(blurMusic && player.current != nil)
                if player.current != nil {
                    if player.isPlaying, mini.panelOpen {
                        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                            VisualizerBars(level: player.meterLevel(), color: theme.opacity(0.9))
                        }
                    } else {
                        VisualizerBars(level: 0, color: theme.opacity(0.9))
                    }
                }
                Spacer()
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    player.playPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    player.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 13))
                        .foregroundStyle(player.isLooping ? theme : .secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help(player.isLooping ? "Looping current song" : "Shuffle next")
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.small)
                    .tint(theme)
                    .frame(width: 74)
                    .pointerCursor()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
        }
        .card()
        .background {
            if let track = player.current {
                AmbientGlow(track: track, player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .animation(.easeInOut(duration: 0.6), value: track.id)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: player.current)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let fraction = dragFraction ?? player.progressNow()
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule()
                    .fill(theme.opacity(0.85))
                    .frame(width: max(3, geo.size.width * fraction))
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded { value in
                        player.seek(to: min(max(value.location.x / geo.size.width, 0), 1))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 5)
        .pointerCursor()
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var player: MusicPlayer
    let track: Track
    @State private var artwork: NSImage?
    @State private var duration: String?
    @State private var hovering = false
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenter = false
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
                    .presenterBlur(presenter && presenterBlurMusic)

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
