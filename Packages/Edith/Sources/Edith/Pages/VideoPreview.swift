import AVKit
import AppKit
import EdithKit
import MediaPlayer
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
    let track: Track
    let player: AVPlayer
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    private var statusObservation: NSKeyValueObservation?

    init(track: Track, startingAt seconds: TimeInterval) {
        self.track = track
        player = AVPlayer(url: track.url)
        player.volume = Float(MusicRemote.shared.volume)
        if seconds > 0 {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.setPlaying(playing) }
        }
        Task { [weak self] in
            guard let item = self?.player.currentItem,
                let loaded = try? await item.asset.load(.duration), loaded.seconds.isFinite
            else { return }
            self?.duration = loaded.seconds
            self?.publishNowPlaying()
        }
    }

    var elapsed: TimeInterval {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    func prepare() {
        installRemoteCommands()
        publishNowPlaying()
    }

    func start() {
        prepare()
        player.play()
    }

    func applyVolume(_ value: Double) {
        player.volume = Float(min(max(value, 0), 1))
    }

    func toggle() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        player.seek(
            to: CMTime(seconds: min(max(fraction, 0), 1) * duration, preferredTimescale: 600))
        publishNowPlaying()
    }

    func stop() {
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeRemoteCommands()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        publishNowPlaying()
        MusicRemote.shared.videoPlaybackChanged()
    }

    private func publishNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let art = TrackMeta.artworkCached(for: track), art.size.width > 0 {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in MusicRemote.shared.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in MusicRemote.shared.previous() }
            return .success
        }
    }

    private func removeRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.nextTrackCommand, center.previousTrackCommand,
        ]
        .forEach { $0.removeTarget(nil) }
    }
}

extension Track {
    var isVideo: Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
}

struct VideoStage: View {
    @ObservedObject private var remote = MusicRemote.shared
    @StateObject private var session: VideoPreviewSession

    init(track: Track, startAt: TimeInterval) {
        _session = StateObject(
            wrappedValue: VideoPreviewSession(track: track, startingAt: startAt))
    }

    var body: some View {
        NativeVideoPlayer(player: session.player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
            .shadow(color: .black.opacity(0.3), radius: UIScale.pt(16), y: UIScale.pt(8))
            .onAppear {
                let takesOverPlayback = remote.isPlaying
                remote.attachVideo(session, resumesAudio: takesOverPlayback)
                if takesOverPlayback {
                    session.start()
                } else {
                    session.prepare()
                }
            }
            .onDisappear {
                remote.detachVideo(session)
                session.stop()
            }
    }
}
