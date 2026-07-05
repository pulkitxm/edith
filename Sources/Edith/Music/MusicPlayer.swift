import AVFoundation
import AppKit
import MediaPlayer

struct Track: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    /// "kishore-kumar-top-12.mp3" → "Kishore Kumar Top 12"
    var title: String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
    /// Stable per-track hue for the no-artwork tile (djb2 - String.hashValue
    /// is randomized per launch and would repaint every restart).
    var hue: Double {
        var h: UInt64 = 5381
        for b in url.lastPathComponent.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360
    }
}

@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published var volume: Double {
        didSet {
            player?.setVolume(Float(volume), fadeDuration: 0.1)
            UserDefaults.standard.set(volume, forKey: "musicVolume")
        }
    }
    /// On track end: repeat the current song when true, else shuffle to a random one.
    @Published var isLooping: Bool {
        didSet { UserDefaults.standard.set(isLooping, forKey: "musicLooping") }
    }

    private var player: AVAudioPlayer?
    private var artworkCache: [URL: NSImage] = [:]
    private let fade: TimeInterval = 0.35

    override init() {
        let saved = UserDefaults.standard.object(forKey: "musicVolume") as? Double
        volume = saved ?? 0.7
        isLooping = UserDefaults.standard.bool(forKey: "musicLooping") // default off
        super.init()
        rescan()
        setupRemoteCommands()
    }

    // Media keys / AirPods / the system Now Playing widget drive the player too.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyPlaybackDuration: trackDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        center.playbackState = isPlaying ? .playing : .paused
    }

    // Everything CoreAudio opens on this machine - verified including mp4 and webm.
    private static let playableExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac", "mp4", "mov", "webm"]

    /// The music folder is the source of truth - a plain directory listing, no manifest.
    func rescan() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Repo.musicDir, includingPropertiesForKeys: nil
        )) ?? []
        tracks = files
            .filter { Self.playableExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Track.init)
        if let current, !tracks.contains(current) {
            stop()
        }
    }

    func toggle(_ track: Track) {
        if current == track {
            isPlaying ? pause() : resume()
        } else {
            play(track)
        }
    }

    func playPause() {
        if isPlaying {
            pause()
        } else if current != nil {
            resume()
        } else if let first = tracks.first {
            play(first)
        }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    /// Jump to a random track, avoiding an immediate repeat when there's a choice.
    func playRandom() {
        if let track = Shuffle.pool(tracks, excluding: current).randomElement() { play(track) }
    }

    private func step(_ delta: Int) {
        guard !tracks.isEmpty else { return }
        let index = current.flatMap { tracks.firstIndex(of: $0) } ?? -delta
        play(tracks[((index + delta) % tracks.count + tracks.count) % tracks.count])
    }

    private func play(_ track: Track) {
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: track.url) else {
            // unreadable file - drop it from the list and move on
            tracks.removeAll { $0 == track }
            return
        }
        player = p
        p.isMeteringEnabled = true
        p.delegate = self
        p.volume = 0
        p.prepareToPlay()
        p.play()
        p.setVolume(Float(volume), fadeDuration: fade) // gentle fade-in keeps it smooth
        current = track
        isPlaying = true
        updateNowPlaying()
    }

    private func pause() {
        guard let p = player else { return }
        p.setVolume(0, fadeDuration: fade)
        isPlaying = false
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
            guard let self, !self.isPlaying else { return } // resumed during the fade
            self.player?.pause()
        }
        updateNowPlaying()
    }

    private func resume() {
        guard let p = player else { return }
        p.play()
        p.setVolume(Float(volume), fadeDuration: fade)
        isPlaying = true
        updateNowPlaying()
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        updateNowPlaying()
    }

    /// Tab disabled → stop audio, release caches, unhook the media keys.
    func shutdown() {
        stop()
        tracks = []
        artworkCache.removeAll()
        durationCache.removeAll()
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
         center.nextTrackCommand, center.previousTrackCommand]
            .forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// 0…1 for the progress bar; polled by a TimelineView that only ticks while visible.
    func progressNow() -> Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    /// 0...1 live output level for the visualizer bars; 0 when paused or
    /// stopped. Polled from TimelineViews that only tick while a player
    /// surface is visible - updateMeters() is cheap.
    func meterLevel() -> Double {
        guard isPlaying, let p = player else { return 0 }
        p.updateMeters()
        return MeterMath.level(fromPower: p.averagePower(forChannel: 0))
    }

    var elapsed: TimeInterval { player?.currentTime ?? 0 }
    var trackDuration: TimeInterval { player?.duration ?? 0 }

    /// Jump to a fraction of the current track (works paused or playing).
    func seek(to fraction: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = min(max(fraction, 0), 0.999) * p.duration
        updateNowPlaying()
    }

    private var durationCache: [URL: TimeInterval] = [:]

    /// "3:42" - loaded lazily per row, cached for the app's lifetime.
    func durationLabel(for track: Track) async -> String? {
        let seconds: TimeInterval
        if let hit = durationCache[track.url] {
            seconds = hit
        } else {
            let asset = AVURLAsset(url: track.url)
            guard let time = try? await asset.load(.duration) else { return nil }
            seconds = time.seconds
            durationCache[track.url] = seconds
        }
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    func artwork(for track: Track) async -> NSImage? {
        if let hit = artworkCache[track.url] { return hit }
        let asset = AVURLAsset(url: track.url)
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                    artworkCache[track.url] = image
                    return image
                }
            }
        }
        // Video containers (mp4/webm/mov): a frame from ~20% in is the thumbnail.
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video), !videoTracks.isEmpty {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 120)
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            let at = CMTime(seconds: max(1, seconds * 0.2), preferredTimescale: 600)
            if let cg = try? await generator.image(at: at).image {
                let image = NSImage(cgImage: cg, size: .zero)
                artworkCache[track.url] = image
                return image
            }
        }
        return nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.isLooping, let current = self.current {
                self.play(current) // repeat the same track
            } else {
                self.playRandom() // shuffle onward → endless background mix
            }
        }
    }
}

enum Shuffle {
    /// Candidates for a random pick: everything but `current`, unless excluding it
    /// would leave nothing (single-track library) — then the whole list.
    static func pool<T: Equatable>(_ all: [T], excluding current: T?) -> [T] {
        let rest = all.filter { $0 != current }
        return rest.isEmpty ? all : rest
    }
}
