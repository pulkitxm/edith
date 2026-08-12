import AppKit
import EdithKit
import SwiftUI

struct ArtworkThumb: View {
    let track: Track
    var player: MusicPlayer
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
        .task(id: track.id) { artwork = await player.artwork(for: track) }
    }
}

struct AmbientGlow: View {
    let track: Track
    var player: MusicPlayer
    @Environment(\.colorScheme) private var scheme
    @State private var artwork: NSImage?

    var body: some View {
        GeometryReader { geo in
            Group {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    LinearGradient(
                        colors: [
                            Color(hue: track.hue, saturation: 0.5, brightness: 0.5),
                            Color(hue: track.hue, saturation: 0.65, brightness: 0.25),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .blur(radius: 50)
            .overlay((scheme == .dark ? Color.black : Color.white).opacity(0.45))
            .clipped()
        }
        .task(id: track.id) { artwork = await player.artwork(for: track) }
        .allowsHitTesting(false)
    }
}
