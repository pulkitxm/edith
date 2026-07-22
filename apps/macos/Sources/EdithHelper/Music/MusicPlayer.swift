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

    private enum QueueSource: Equatable {
        case all
        case folder(String)
        case directory(String)
    }

    private var player: AVAudioPlayer?
    private var queueSource: QueueSource = .all
    private let fade: TimeInterval = 0.35
    private var saveTimer: Timer?
    private var folderChangedObserver: NSObjectProtocol?
    private var folderChangedIPCObserver: NSObjectProtocol?
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
        folderChangedIPCObserver = IPC.observe(IPC.Name.musicFolderChanged) { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        broadcastState()
    }

    private func track(for relativePath: String) -> Track {
        tracks.first { $0.relativePath == relativePath }
            ?? Track(url: Repo.musicDir.appendingPathComponent(relativePath))
    }

    private func source(from info: [AnyHashable: Any]) -> QueueSource? {
        guard let kind = info["sourceKind"] as? String else { return nil }
        let path = info["sourcePath"] as? String ?? ""
        switch kind {
        case "folder": return .folder(path)
        case "directory": return .directory(path)
        case "all": return .all
        default: return nil
        }
    }

    private func currentQueue() -> [Track] {
        switch queueSource {
        case .all: return tracks
        case .folder(let path): return TrackMeta.tracks(under: path)
        case .directory(let path): return TrackMeta.entries(in: path).tracks
        }
    }

    private func handleCommand(_ info: [AnyHashable: Any]) {
        switch info["action"] as? String {
        case "playPause": playPause()
        case "next": next()
        case "previous": previous()
        case "toggle":
            if let file = info["track"] as? String {
                toggle(track(for: file))
            }
        case "playSource":
            if let source = source(from: info) {
                playSource(source, start: (info["start"] as? String).map { track(for: $0) })
            }
        case "renamed":
            if let from = info["from"] as? String, let to = info["to"] as? String {
                handleRenamed(from: from, to: to)
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

    private func handleRenamed(from: String, to: String) {
        guard current?.relativePath == from else { return }
        current = track(for: to)
        updateNowPlaying()
        persistPlayback()
        broadcastState()
    }

    private func broadcastState() {
        IPC.post(
            IPC.Name.musicState,
            userInfo: [
                "track": current?.relativePath ?? "",
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
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.playPause()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.playPause()
            }
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
        if let current, !isPlaying, !tracks.contains(current) {
            stop()
        }
    }

    func toggle(_ track: Track) {
        if current == track {
            isPlaying ? pause() : resume()
        } else {
            queueSource = .directory((track.relativePath as NSString).deletingLastPathComponent)
            play(track)
        }
    }

    private func playSource(_ source: QueueSource, start: Track?) {
        let previousSource = queueSource
        queueSource = source
        guard let track = start ?? currentQueue().first else {
            queueSource = previousSource
            return
        }
        play(track)
    }

    func playPause() {
        if isPlaying {
            pause()
        } else if current != nil {
            resume()
        } else if let first = currentQueue().first {
            play(first)
        }
    }

    func next() { step(1) }
    func previous() { step(-1) }

    private func step(_ delta: Int) {
        let list = currentQueue()
        let position = current.flatMap { list.firstIndex(of: $0) }
        guard
            let next = PlayQueue.index(after: position, delta: delta, count: list.count)
        else { return }
        play(list[next])
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
        Task { [weak self] in
            guard let self, let current = self.current, current == track else { return }
            guard let art = await self.artwork(for: track) else { return }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: art.size
            ) { _ in art }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
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
        if let folderChangedIPCObserver {
            IPC.stopObserving(folderChangedIPCObserver)
            self.folderChangedIPCObserver = nil
        }
    }

    func progressNow() -> Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
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
        PlaybackStore.save(
            track: current.relativePath, position: elapsed, playing: isPlaying,
            into: .standard)
    }

    private func restoreLastPlayback() {
        guard current == nil,
            let snapshot = PlaybackStore.load(from: .standard),
            let track = tracks.first(where: { $0.relativePath == snapshot.track })
        else { return }
        guard let p = try? AVAudioPlayer(contentsOf: track.url) else { return }
        player = p
        p.isMeteringEnabled = true
        p.delegate = self
        p.volume = Float(volume)
        p.prepareToPlay()
        if snapshot.position > 0, snapshot.position < p.duration {
            p.currentTime = snapshot.position
        }
        current = track
        if snapshot.playing {
            p.play()
            isPlaying = true
            startSaveTimer()
        } else {
            isPlaying = false
        }
        updateNowPlaying()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.isLooping, let current = self.current {
                self.play(current)
            } else {
                self.step(1)
            }
        }
    }
}

enum PlayQueue {
    static func index(after current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = current ?? -delta
        return ((base + delta) % count + count) % count
    }
}

enum PlaybackStore {
    static let trackKey = "musicLastTrack"
    static let positionKey = "musicLastPosition"
    static let playingKey = "musicWasPlaying"

    struct Snapshot: Equatable {
        let track: String
        let position: Double
        let playing: Bool
    }

    static func save(track: String, position: Double, playing: Bool, into defaults: UserDefaults) {
        defaults.set(track, forKey: trackKey)
        defaults.set(position, forKey: positionKey)
        defaults.set(playing, forKey: playingKey)
    }

    static func load(from defaults: UserDefaults) -> Snapshot? {
        guard let track = defaults.string(forKey: trackKey) else { return nil }
        return Snapshot(
            track: track, position: defaults.double(forKey: positionKey),
            playing: defaults.bool(forKey: playingKey))
    }
}
