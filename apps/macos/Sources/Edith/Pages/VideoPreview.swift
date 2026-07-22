import AVKit
import AppKit
import EdithKit
import SwiftUI

struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

@MainActor
final class VideoPreviewSession: ObservableObject {
    let player: AVPlayer

    init(url: URL, startingAt seconds: TimeInterval) {
        player = AVPlayer(url: url)
        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }

    var elapsed: TimeInterval {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    func start() { player.play() }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

extension Track {
    var isVideo: Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
}

struct VideoStage: View {
    let track: Track
    let onOpen: () -> Void
    let onClose: (TimeInterval, Bool) -> Void
    @ObservedObject private var remote = MusicRemote.shared
    @StateObject private var session: VideoPreviewSession
    @State private var handedOverWhilePlaying = false

    init(
        track: Track, startAt: TimeInterval, onOpen: @escaping () -> Void,
        onClose: @escaping (TimeInterval, Bool) -> Void
    ) {
        self.track = track
        self.onOpen = onOpen
        self.onClose = onClose
        _session = StateObject(
            wrappedValue: VideoPreviewSession(url: track.url, startingAt: startAt))
    }

    var body: some View {
        NativeVideoPlayer(player: session.player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .shadow(color: .black.opacity(0.3), radius: UIScale.pt(16), y: UIScale.pt(8))
            .onAppear {
                handedOverWhilePlaying = remote.isPlaying
                onOpen()
                session.start()
            }
            .onChange(of: remote.isPlaying) {
                if remote.isPlaying { session.pause() }
            }
            .onDisappear {
                let position = session.elapsed
                session.stop()
                onClose(position, handedOverWhilePlaying)
            }
    }
}
