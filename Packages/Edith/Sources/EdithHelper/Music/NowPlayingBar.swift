import EdithKit
import SwiftUI

struct NowPlayingBar: View {
    @Bindable var player: MusicPlayer
    let theme: Color
    @State private var dragFraction: Double?
    private var presenterState = PresenterState.shared
    @AppStorage(AppStorageKeys.Presenter.blurMusic, store: SharedDefaults.store) private
        var presenterBlurMusic = true

    private var blurMusic: Bool { presenterState.active && presenterBlurMusic }

    init(player: MusicPlayer, theme: Color) {
        self.player = player
        self.theme = theme
    }

    var body: some View {
        if let track = player.current {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ArtworkThumb(track: track, player: player, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .presenterBlur(blurMusic)
                        Group {
                            if player.isPlaying {
                                TimelineView(.periodic(from: MusicTick.epoch, by: 1)) { _ in
                                    timeText
                                }
                            } else {
                                timeText
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    PlaybackWave(playing: player.isPlaying, color: theme.opacity(0.9))
                    Button {
                        player.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Button {
                        player.playPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Button {
                        player.isShuffling.toggle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.system(size: 12))
                            .foregroundStyle(player.isShuffling ? theme : .secondary)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help(
                        player.isShuffling
                            ? "Shuffling this folder and everything in it" : "Play in order")
                    Button {
                        player.isLooping.toggle()
                    } label: {
                        Image(systemName: "repeat")
                            .font(.system(size: 12))
                            .foregroundStyle(player.isLooping ? theme : .secondary)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help(player.isLooping ? "Repeating this track" : "Play through the queue")
                    Slider(value: $player.volume, in: 0...1)
                        .controlSize(.mini)
                        .tint(theme)
                        .frame(width: 60)
                        .pointerCursor()
                }
                scrubber
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .background {
                AmbientGlow(track: track, player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .animation(.easeInOut(duration: 0.6), value: track.id)
            }
            .animation(.easeInOut(duration: 0.6), value: track.id)
        }
    }

    private var timeText: some View {
        Text("\(timeLabel(player.elapsed)) / \(timeLabel(player.trackDuration))")
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let knob: CGFloat = 10
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                if player.isPlaying, dragFraction == nil {
                    TimelineView(.periodic(from: MusicTick.epoch, by: 0.5)) { _ in
                        fill(geo.size.width, knob)
                    }
                } else {
                    fill(geo.size.width, knob)
                }
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

    private func fill(_ width: CGFloat, _ knob: CGFloat) -> some View {
        let fraction = dragFraction ?? player.progressNow()
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.opacity(0.85))
                .frame(width: width)
                .mask(alignment: .leading) {
                    Rectangle()
                        .scaleEffect(
                            x: width > 0 ? max(3, width * fraction) / width : 0, anchor: .leading)
                }
            Circle()
                .fill(theme)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .offset(x: min(max(width * fraction - knob / 2, 0), width - knob))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
