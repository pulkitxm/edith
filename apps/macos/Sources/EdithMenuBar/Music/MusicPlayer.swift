import AVFoundation
import AppKit
import EdithKit
import MediaPlayer

@MainActor
final class MusicPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, FeatureModule {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    @Published var volume: Double {
        didSet {
            player?.setVolume(Float(volume), fadeDuration: 0.1)
            UserDefaults.standard.set(volume, forKey: "musicVolume")
            broadcastState()
        }
    }
    @Published var isLooping: Bool {
        didSet {
            UserDefaults.standard.set(isLooping, forKey: "musicLooping")
            broadcastState()
        }
    }

    private var player: AVAudioPlayer?
    private let fade: TimeInterval = 0.35
    private var saveTimer: Timer?
    private var folderChangedObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?
    private var stateRequestObserver: NSObjectProtocol?

    override init() {
        let saved = UserDefaults.standard.object(forKey: "musicVolume") as? Double
        volume = saved ?? 0.7
        isLooping = UserDefaults.standard.bool(forKey: "musicLooping")
        super.init()
        rescan()
        restoreLastPlayback()
        setupRemoteCommands()
        folderChangedObserver = NotificationCenter.default.addObserver(
            forName: .musicFolderChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        commandObserver = IPC.observe(
            IPC.Name.musicCommand,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.handleCommand(info) }
            })
        stateRequestObserver = IPC.observe(IPC.Name.requestMusicState) { [weak self] in
            MainActor.assumeIsolated { self?.broadcastState() }
        }
        broadcastState()
    }

    private func handleCommand(_ info: [AnyHashable: Any]) {
        switch info["action"] as? String {
        case "playPause": playPause()
        case "next": next()
        case "previous": previous()
        case "toggle":
            if let file = info["track"] as? String,
                let track = tracks.first(where: { $0.url.lastPathComponent == file })
            {
                toggle(track)
            }
        case "seek":
            if let fraction = info["value"] as? Double { seek(to: fraction) }
        case "volume":
            if let value = info["value"] as? Double { volume = min(max(value, 0), 1) }
        case "loop":
            if let value = info["value"] as? Bool { isLooping = value }
        default: break
        }
    }

    private func broadcastState() {
        IPC.post(
            IPC.Name.musicState,
            userInfo: [
                "track": current?.url.lastPathComponent ?? "",
                "isPlaying": isPlaying,
                "elapsed": elapsed,
                "duration": trackDuration,
                "volume": volume,
                "looping": isLooping,
                "at": Date().timeIntervalSince1970,
            ])
    }

    private func startSaveTimer() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persistPlayback() }
        }
        saveTimer?.tolerance = 5
    }

    private func stopSaveTimer() {
        saveTimer?.invalidate()
        saveTimer = nil
    }

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

    func rescan() {
        tracks = TrackMeta.scanMusicFolder()
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
            tracks.removeAll { $0 == track }
            return
        }
        player = p
        p.isMeteringEnabled = true
        p.delegate = self
        p.volume = 0
        p.prepareToPlay()
        p.play()
        p.setVolume(Float(volume), fadeDuration: fade)
        current = track
        isPlaying = true
        startSaveTimer()
        updateNowPlaying()
        persistPlayback()
        broadcastState()
    }

    private func pause() {
        guard let p = player else { return }
        p.setVolume(0, fadeDuration: fade)
        isPlaying = false
        stopSaveTimer()
        persistPlayback()
        DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.player?.pause()
        }
        updateNowPlaying()
        broadcastState()
    }

    private func resume() {
        guard let p = player else { return }
        p.play()
        p.setVolume(Float(volume), fadeDuration: fade)
        isPlaying = true
        startSaveTimer()
        updateNowPlaying()
        broadcastState()
    }

    func stop() {
        persistPlayback()
        stopSaveTimer()
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        updateNowPlaying()
        broadcastState()
    }

    func shutdown() {
        stop()
        tracks = []
        let center = MPRemoteCommandCenter.shared()
        [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.nextTrackCommand, center.previousTrackCommand,
        ]
        .forEach { $0.removeTarget(nil) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let folderChangedObserver {
            NotificationCenter.default.removeObserver(folderChangedObserver)
            self.folderChangedObserver = nil
        }
        if let commandObserver {
            IPC.stopObserving(commandObserver)
            self.commandObserver = nil
        }
        if let stateRequestObserver {
            IPC.stopObserving(stateRequestObserver)
            self.stateRequestObserver = nil
        }
    }

    func progressNow() -> Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    func meterLevel() -> Double {
        guard isPlaying, let p = player else { return 0 }
        p.updateMeters()
        return MeterMath.level(fromPower: p.averagePower(forChannel: 0))
    }

    var elapsed: TimeInterval { player?.currentTime ?? 0 }
    var trackDuration: TimeInterval { player?.duration ?? 0 }

    func seek(to fraction: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = min(max(fraction, 0), 0.999) * p.duration
        objectWillChange.send()
        updateNowPlaying()
        persistPlayback()
        broadcastState()
    }

    func durationLabel(for track: Track) async -> String? {
        await TrackMeta.durationLabel(for: track)
    }

    func artwork(for track: Track) async -> NSImage? {
        await TrackMeta.artwork(for: track)
    }

    private func persistPlayback() {
        guard let current else { return }
        UserDefaults.standard.set(current.url.lastPathComponent, forKey: "musicLastTrack")
        UserDefaults.standard.set(elapsed, forKey: "musicLastPosition")
    }

    private func restoreLastPlayback() {
        guard current == nil,
            let name = UserDefaults.standard.string(forKey: "musicLastTrack"),
            let track = tracks.first(where: { $0.url.lastPathComponent == name })
        else { return }
        let position = UserDefaults.standard.double(forKey: "musicLastPosition")
        guard let p = try? AVAudioPlayer(contentsOf: track.url) else { return }
        player = p
        p.isMeteringEnabled = true
        p.delegate = self
        p.volume = Float(volume)
        p.prepareToPlay()
        if position > 0, position < p.duration { p.currentTime = position }
        current = track
        isPlaying = false
        updateNowPlaying()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.isLooping, let current = self.current {
                self.play(current)
            } else {
                self.playRandom()
            }
        }
    }
}

enum Shuffle {
    static func pool<T: Equatable>(_ all: [T], excluding current: T?) -> [T] {
        let rest = all.filter { $0 != current }
        return rest.isEmpty ? all : rest
    }
}
