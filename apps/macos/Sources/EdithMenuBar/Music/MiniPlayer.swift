import EdithKit
import SwiftUI

struct MiniPlayer: View {
    @ObservedObject var player: MusicPlayer
    let theme: Color
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenter = false
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true

    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkThumb(track: track, player: player, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .presenterBlur(presenter && presenterBlurMusic)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(timeLabel(player.elapsed)) / \(timeLabel(player.trackDuration))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if player.isPlaying {
                    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                        VisualizerBars(level: player.meterLevel(), color: theme.opacity(0.9))
                    }
                } else {
                    VisualizerBars(level: 0, color: theme.opacity(0.9))
                }
                Button {
                    player.playPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                Button {
                    player.isLooping.toggle()
                } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 12))
                        .foregroundStyle(player.isLooping ? theme : .secondary)
                }
                .buttonStyle(HoverButtonStyle())
                .help(player.isLooping ? "Looping current song" : "Shuffle next")
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .tint(theme)
                    .frame(width: 60)
                    .pointerCursor()
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.6), value: track.id)
        }
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
