import EdithKit
import SwiftUI

struct ExternalPlayerBar: View {
    @ObservedObject var external: ExternalMusic
    let theme: Color
    @State private var dragFraction: Double?
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true

    private var blurMusic: Bool { presenterState.active && presenterBlurMusic }

    private var volumeBinding: Binding<Double> {
        Binding(get: { external.volume }, set: { external.setVolume($0) })
    }

    var body: some View {
        if let track = external.current {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    thumb(track)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .presenterBlur(blurMusic)
                        HStack(spacing: 6) {
                            Text(track.artist.isEmpty ? track.app.label : track.artist)
                                .lineLimit(1)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(
                                    "\(timeLabel(external.elapsedNow())) / \(timeLabel(track.duration))"
                                )
                                .monospacedDigit()
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: track.app == .spotify ? "music.note" : "applelogo")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.opacity(0.8))
                        .help("Playing in \(track.app.label)")
                    Button {
                        external.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Button {
                        external.playPause()
                    } label: {
                        Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Button {
                        external.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme)
                    }
                    .buttonStyle(HoverButtonStyle())
                    Slider(value: volumeBinding, in: 0...1)
                        .controlSize(.mini)
                        .tint(theme)
                        .frame(width: 60)
                        .pointerCursor()
                }
                scrubber(track)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .animation(.easeInOut(duration: 0.6), value: track.artKey)
        }
    }

    private func thumb(_ track: ExternalTrack) -> some View {
        Group {
            if let artwork = external.artwork {
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
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func scrubber(_ track: ExternalTrack) -> some View {
        GeometryReader { geo in
            let knob: CGFloat = 10
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let fraction = dragFraction ?? external.progressNow()
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.opacity(0.85))
                            .frame(width: max(3, geo.size.width * fraction))
                        Circle()
                            .fill(theme)
                            .frame(width: knob, height: knob)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .offset(
                                x: min(
                                    max(geo.size.width * fraction - knob / 2, 0),
                                    geo.size.width - knob))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded { value in
                        external.seek(to: min(max(value.location.x / geo.size.width, 0), 1))
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
