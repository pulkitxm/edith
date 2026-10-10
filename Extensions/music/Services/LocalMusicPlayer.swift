import AVFoundation
import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import MediaPlayer

@MainActor
@Observable
final class LocalMusicPlayer: NSObject, AVAudioPlayerDelegate, FeatureModule {
    @ObservationIgnored private let tasks = MusicTaskOwner()
    @ObservationIgnored private var stopped = false
    @ObservationIgnored var presentationTransport: ((MusicTransportRequest) -> Bool)?
    @ObservationIgnored var presentationSnapshot: (() -> PlayerSnapshot?)?
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private let mediaControlsEnabled: Bool
    private(set) var tracks: [Track] = []
    private(set) var current: Track?
    private(set) var isPlaying = false
    var volume: Double {
        didSet {
            player?.setVolume(Float(volume), fadeDuration: 0.1)
            scheduleVolumePersist()
            broadcastState()
        }
    }
    var isLooping: Bool {
        didSet {
            SharedDefaults.store.set(isLooping, forKey: AppStorageKeys.Music.looping)
            broadcastState()
        }
    }
    var isShuffling: Bool {
        didSet {
            SharedDefaults.store.set(isShuffling, forKey: AppStorageKeys.Music.shuffling)
            if case .directory = queueSource { queueCache = nil }
            shuffledCache = nil
            broadcastState()
        }
    }

    private enum QueueSource: Equatable {
        case all
        case folder(String)
        case directory(String)
        case favourites
    }

    private var player: AVAudioPlayer?
    private var queueSource: QueueSource = .all {
        didSet {
            guard queueSource != oldValue else { return }
            queueCache = nil
            shuffledCache = nil
            history.removeAll()
        }
    }
    private var queueCache: [Track]?
    private var shuffledCache: [Track]?
    private var history: [Track] = []
    private var fadingOut: [AVAudioPlayer] = []
    private var loadGeneration = 0
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var lastBroadcast: TimeInterval = 0
    private var broadcastScheduled = false
    private let broadcastInterval: TimeInterval = 0.05
    private var artworkTrack: Track?
    private let fade: TimeInterval = 0.35
    private var saveTimer: Timer?
    private var volumePersistWorkItem: DispatchWorkItem?
    private var levelTimer: Timer?
    private var levelSubscriberUntil = Date.distantPast
    private var smoothedLevel = 0.0
    private var systemVolume = 1.0
    private var levelTick = 0
    private var levelRequestObserver: NSObjectProtocol?
    private var favouritesObserver: NSObjectProtocol?
    private var folderChangedObserver: NSObjectProtocol?
    private var folderChangedIPCObserver: NSObjectProtocol?
    private var commandObserver: NSObjectProtocol?
    private var stateRequestObserver: NSObjectProtocol?

    override convenience init() {
        self.init(
            mediaControlsEnabled: ProcessInfo.processInfo.environment[
                "EDITH_EXTENSION_FIXTURE_HOME"] == nil)
    }

    init(mediaControlsEnabled: Bool) {
        self.mediaControlsEnabled = mediaControlsEnabled
        let saved = SharedDefaults.store.object(forKey: AppStorageKeys.Music.volume) as? Double
        volume = saved ?? 0.7
        isLooping = SharedDefaults.store.bool(forKey: AppStorageKeys.Music.looping)
        isShuffling = SharedDefaults.store.bool(forKey: AppStorageKeys.Music.shuffling)
        super.init()
        rescan()
        restoreLastPlayback()
        if mediaControlsEnabled { setupRemoteCommands() }
        folderChangedObserver = NotificationCenter.default.addObserver(
            forName: .musicFolderChangedLocally, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        commandObserver = MusicEvents.observe(
            MusicEvents.Name.musicCommand,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.handleCommand(info) }
            })
        stateRequestObserver = MusicEvents.observe(MusicEvents.Name.requestMusicState) {
            [weak self] in
            MainActor.assumeIsolated {
                self?.perform(.status)
            }
        }
        folderChangedIPCObserver = MusicEvents.observe(MusicEvents.Name.musicFolderChanged) {
            [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        favouritesObserver = MusicEvents.observe(MusicEvents.Name.musicFavouritesChanged) {
            [weak self] in
            MainActor.assumeIsolated { self?.queueCache = nil }
        }
        levelRequestObserver = MusicEvents.observe(MusicEvents.Name.requestMusicLevels) {
            [weak self] in
            MainActor.assumeIsolated {
                _ = self?.readLevel()
            }
        }
        PlaybackLevel.shared.onViewersChange = { [weak self] in self?.resumeLevelTimer() }
        broadcastState()
    }

    private func track(for relativePath: String) -> Track {
        Track(url: TrackMeta.url(for: relativePath), relativePath: relativePath)
    }

    private func source(from info: [AnyHashable: Any]) -> QueueSource? {
        switch MusicSourceRequest.decode(info) {
        case let .folder(path): return .folder(path)
        case let .directory(path): return .directory(path)
        case .favourites: return .favourites
        case .all: return .all
        case nil: return nil
        }
    }

    private func queue() async -> [Track] {
        if let queueCache { return queueCache }
        let source = queueSource
        let list: [Track]
        switch source {
        case .all:
            list = tracks
        case .favourites:
            list = Favourites.tracks()
        case .folder(let path):
            list = await MusicTaskOwner.detached { TrackMeta.tracks(under: path) }
        case .directory(let path) where isShuffling:
            list = await MusicTaskOwner.detached { TrackMeta.tracks(under: path) }
        case .directory(let path):
            list = await MusicTaskOwner.detached { TrackMeta.entries(in: path).tracks }
        }
        if queueSource == source { queueCache = list }
        return list
    }

    private func playOrder() async -> [Track] {
        let natural = await queue()
        guard isShuffling else { return natural }
        let order = PlayQueue.shuffleOrder(
            previous: shuffledCache, natural: natural, current: current)
        shuffledCache = order
        return order
    }

    private func handleCommand(_ info: [AnyHashable: Any]) {
        switch info["action"] as? String {
        case "playPause": playPause()
        case "pause":
            if isPlaying { pause() }
        case "resume":
            if !isPlaying, current != nil { resume() }
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
                renameCurrent(from, to)
            }
        case "seek":
            if let fraction = info["value"] as? Double { seek(to: fraction) }
        case "volume":
            if let value = info["value"] as? Double { volume = min(max(value, 0), 1) }
        case "loop":
            if let value = info["value"] as? Bool { isLooping = value }
        case "shuffle":
            if let value = info["value"] as? Bool { isShuffling = value }
        default: break
        }
    }

    func perform(_ request: MusicTransportRequest) {
        guard !stopped else { return }
        if presentationTransport?(request) == true { return }
        MusicTransportExecution.perform(
            request, sendCommand: { handleCommand($0) },
            requestStatus: {
                updateNowPlaying()
                broadcastState()
            })
    }

    func upcoming(limit: Int) async -> [Track] {
        let order = await playOrder()
        guard let current, let index = order.firstIndex(of: current) else { return [] }
        return Array(order.dropFirst(index + 1).prefix(max(0, min(limit, 10))))
    }

    func renameCurrent(_ from: String, _ to: String) {
        guard current?.relativePath == from else { return }
        current = track(for: to)
        updateNowPlaying()
        persistPlayback()
        broadcastState()
    }

    private func broadcastState() {
        let now = Date().timeIntervalSince1970
        guard now - lastBroadcast < broadcastInterval else {
            lastBroadcast = now
            postState()
            return
        }
        guard !broadcastScheduled else { return }
        broadcastScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + broadcastInterval) { [weak self] in
            guard let self, !self.stopped else { return }
            self.broadcastScheduled = false
            self.lastBroadcast = Date().timeIntervalSince1970
            self.postState()
        }
    }

    private func postState() {
        MusicEvents.post(
            MusicEvents.Name.musicState,
            userInfo: [
                "track": current?.relativePath ?? "",
                "isPlaying": isPlaying,
                "elapsed": elapsed,
                "duration": trackDuration,
                "volume": volume,
                "looping": isLooping,
                "shuffling": isShuffling,
                "at": Date().timeIntervalSince1970,
            ])
    }

    private func scheduleVolumePersist() {
        volumePersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.volumePersistWorkItem = nil
            SharedDefaults.store.set(self.volume, forKey: AppStorageKeys.Music.volume)
        }
        volumePersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func flushVolumePersist() {
        guard let work = volumePersistWorkItem else { return }
        work.cancel()
        volumePersistWorkItem = nil
        SharedDefaults.store.set(volume, forKey: AppStorageKeys.Music.volume)
    }

    private func startSaveTimer() {
        startLevelTimer()
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.persistPlayback() }
        }
        saveTimer?.tolerance = 5
    }

    private func stopSaveTimer() {
        stopLevelTimer()
        saveTimer?.invalidate()
        saveTimer = nil
    }

    func readLevel() -> Double {
        levelSubscriberUntil = Date().addingTimeInterval(2.5)
        resumeLevelTimer()
        return PlaybackLevel.shared.level
    }

    private var levelDemanded: Bool {
        PlaybackLevel.shared.viewers > 0 || Date() < levelSubscriberUntil
    }

    private func resumeLevelTimer() {
        guard saveTimer != nil else { return }
        startLevelTimer()
    }

    private func startLevelTimer() {
        guard levelTimer == nil, levelDemanded else { return }
        levelTick = 0
        systemVolume = SystemVolume.current()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.sampleLevel() }
        }
        levelTimer?.tolerance = 0.01
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        smoothedLevel = 0
        PlaybackLevel.shared.reset()
        if Date() < levelSubscriberUntil {
            MusicEvents.post(
                MusicEvents.Name.musicLevel, userInfo: ["level": PlaybackLevel.neutral])
        }
    }

    private func sampleLevel() {
        guard levelDemanded else {
            stopLevelTimer()
            return
        }
        guard let p = player, p.isPlaying else { return }
        p.updateMeters()
        if levelTick % 3 == 0 { systemVolume = SystemVolume.current() }
        let channels = max(min(p.numberOfChannels, 2), 1)
        let loudest = (0..<channels).map { Double(p.averagePower(forChannel: $0)) }.max() ?? -60
        smoothedLevel = MeterLevel.level(
            decibels: loudest,
            gain: MeterLevel.gain(appVolume: volume, systemVolume: systemVolume),
            previous: smoothedLevel)
        PlaybackLevel.shared.update(smoothedLevel)
        levelTick += 1
        guard levelTick % 2 == 0, Date() < levelSubscriberUntil else { return }
        MusicEvents.post(MusicEvents.Name.musicLevel, userInfo: ["level": smoothedLevel])
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, request) in [
            (center.playCommand, MusicTransportRequest.play), (center.pauseCommand, .pause),
            (center.togglePlayPauseCommand, .toggle), (center.nextTrackCommand, .next),
            (center.previousTrackCommand, .previous),
        ] {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in self?.perform(request) }
                return .success
            }
            remoteTargets.append((command, target))
        }
    }

    var nowPlayingSnapshot: PlayerSnapshot {
        presentationSnapshot?()
            ?? PlayerSnapshot(
                player: .builtin, isRunning: !stopped, isPlaying: isPlaying,
                title: current?.title ?? "",
                elapsedSeconds: elapsed, durationSeconds: trackDuration, volume: volume,
                trackPath: current?.relativePath)
    }

    func presentationDidChange() { updateNowPlaying() }

    private func updateNowPlaying() {
        guard mediaControlsEnabled else { return }
        let center = MPNowPlayingInfoCenter.default()
        let snapshot = nowPlayingSnapshot
        guard snapshot.hasTrack else {
            nowPlayingArtwork = nil
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyPlaybackDuration: snapshot.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
        ]
        if let path = snapshot.trackPath {
            let track = track(for: path)
            if let art = TrackMeta.artworkCached(for: track), art.size.width > 0 {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in
                    art
                }
            } else if let artwork = nowPlayingArtwork, artworkTrack?.relativePath == path {
                info[MPMediaItemPropertyArtwork] = artwork
            }
        }
        center.nowPlayingInfo = info
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    private func attachArtwork(_ image: NSImage, for track: Track) {
        guard current == track, image.size.width > 0, image.size.height > 0 else { return }
        nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkTrack = track
        updateNowPlaying()
    }

    func rescan() {
        TrackMeta.invalidateCaches()
        queueCache = nil
        tasks.start { [weak self] in
            let scanned = await MusicTaskOwner.detached { TrackMeta.scanMusicFolder() }
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.tracks = scanned
            if let current = self.current, !self.isPlaying, !scanned.contains(current) {
                self.stop()
            }
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
        if let start {
            play(start)
            return
        }
        tasks.start { [weak self] in
            guard let self, !Task.isCancelled, !self.stopped else { return }
            guard let first = await self.playOrder().first else {
                self.queueSource = previousSource
                return
            }
            self.play(first)
        }
    }

    func playPause() {
        if isPlaying {
            pause()
        } else if current != nil {
            resume()
        } else {
            tasks.start { [weak self] in
                guard let self, let first = await self.playOrder().first else { return }
                self.play(first)
            }
        }
    }

    func next() { step(1) }

    func previous() {
        if PlayQueue.previousRestarts(elapsed: elapsed) {
            seek(to: 0)
            return
        }
        if let previous = history.popLast() {
            play(previous, remember: false)
            return
        }
        step(-1, remember: false)
    }

    private func step(_ delta: Int, remember: Bool = true) {
        tasks.start { [weak self] in
            guard let self, !Task.isCancelled, !self.stopped else { return }
            let list = await self.playOrder()
            let position = self.current.flatMap { list.firstIndex(of: $0) }
            guard let next = PlayQueue.index(after: position, delta: delta, count: list.count)
            else { return }
            self.play(list[next], remember: remember)
        }
    }

    private func remember(_ track: Track) {
        guard let current, current != track else { return }
        history.append(current)
        if history.count > PlayQueue.historyLimit {
            history.removeFirst(history.count - PlayQueue.historyLimit)
        }
    }

    private func play(_ track: Track, remember shouldRemember: Bool = true) {
        if shouldRemember { remember(track) }
        let crossfade = MusicFade.duration(from: SharedDefaults.store)
        loadGeneration += 1
        let generation = loadGeneration
        current = track
        isPlaying = true
        startSaveTimer()
        updateNowPlaying()
        broadcastState()
        tasks.start { [weak self] in
            let loaded = await MusicTaskOwner.detached { LoadedAudio(url: track.url) }
            guard let self, self.loadGeneration == generation else { return }
            guard let loaded else {
                self.tracks.removeAll { $0 == track }
                self.queueCache?.removeAll { $0 == track }
                return
            }
            self.install(loaded.player, for: track, crossfade: crossfade)
        }
    }

    private func install(_ p: AVAudioPlayer, for track: Track, crossfade: TimeInterval) {
        retirePlayer(over: crossfade)
        player = p
        p.isMeteringEnabled = true
        p.delegate = self
        p.volume = 0
        if isPlaying {
            p.play()
            p.setVolume(Float(volume), fadeDuration: max(crossfade, fade))
        }
        updateNowPlaying()
        persistPlayback()
        broadcastState()
        tasks.start { [weak self] in
            guard let self, self.current == track else { return }
            guard let art = await self.artwork(for: track) else { return }
            self.attachArtwork(art, for: track)
        }
    }

    private func retirePlayer(over crossfade: TimeInterval) {
        guard let outgoing = player else { return }
        player = nil
        outgoing.delegate = nil
        guard crossfade > 0, outgoing.isPlaying else {
            outgoing.stop()
            return
        }
        outgoing.setVolume(0, fadeDuration: crossfade)
        fadingOut.append(outgoing)
        DispatchQueue.main.asyncAfter(deadline: .now() + crossfade) { [weak self] in
            outgoing.stop()
            self?.fadingOut.removeAll { $0 === outgoing }
        }
    }

    private func pause() {
        isPlaying = false
        stopSaveTimer()
        persistPlayback()
        if let p = player {
            p.setVolume(0, fadeDuration: fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self] in
                guard let self, !self.isPlaying else { return }
                self.player?.pause()
            }
        }
        updateNowPlaying()
        broadcastState()
    }

    private func resume() {
        isPlaying = true
        startSaveTimer()
        if let p = player {
            p.play()
            p.setVolume(Float(volume), fadeDuration: fade)
        }
        updateNowPlaying()
        broadcastState()
    }

    func stop() {
        persistPlayback()
        stopSaveTimer()
        loadGeneration += 1
        fadingOut.forEach { $0.stop() }
        fadingOut.removeAll()
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        updateNowPlaying()
        broadcastState()
    }

    func shutdown() {
        guard !stopped else { return }
        tasks.shutdown()
        stop()
        stopped = true
        queueCache = nil
        shuffledCache = nil
        history.removeAll()
        PlaybackLevel.shared.onViewersChange = nil
        if let favouritesObserver {
            MusicEvents.stopObserving(favouritesObserver); self.favouritesObserver = nil
        }
        flushVolumePersist()
        tracks = []
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll(); presentationSnapshot = nil; presentationTransport = nil
        if mediaControlsEnabled { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        if let folderChangedObserver {
            NotificationCenter.default.removeObserver(folderChangedObserver)
            self.folderChangedObserver = nil
        }
        if let commandObserver {
            MusicEvents.stopObserving(commandObserver)
            self.commandObserver = nil
        }
        if let stateRequestObserver {
            MusicEvents.stopObserving(stateRequestObserver)
            self.stateRequestObserver = nil
        }
        if let folderChangedIPCObserver {
            MusicEvents.stopObserving(folderChangedIPCObserver)
            self.folderChangedIPCObserver = nil
        }
        if let levelRequestObserver {
            MusicEvents.stopObserving(levelRequestObserver)
            self.levelRequestObserver = nil
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
            into: SharedDefaults.store)
    }

    private func restoreLastPlayback() {
        guard current == nil, let snapshot = PlaybackStore.load(from: SharedDefaults.store) else {
            return
        }
        let track = self.track(for: snapshot.track)
        loadGeneration += 1
        let generation = loadGeneration
        current = track
        isPlaying = false
        updateNowPlaying()
        tasks.start { [weak self] in
            let loaded = await MusicTaskOwner.detached { LoadedAudio(url: track.url) }
            guard let self, self.loadGeneration == generation else { return }
            guard let loaded else {
                if self.current == track { self.current = nil }
                self.updateNowPlaying()
                self.broadcastState()
                return
            }
            self.installRestored(loaded.player, for: track, snapshot: snapshot)
        }
    }

    private func installRestored(
        _ p: AVAudioPlayer, for track: Track, snapshot: PlaybackStore.Snapshot
    ) {
        guard current == track else { return }
        player = p
        p.isMeteringEnabled = true
        p.delegate = self
        p.volume = Float(volume)
        if snapshot.position > 0, snapshot.position < p.duration {
            p.currentTime = snapshot.position
        }
        if snapshot.playing {
            p.play()
            isPlaying = true
            startSaveTimer()
        } else {
            isPlaying = false
        }
        updateNowPlaying()
        broadcastState()
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

final class LoadedAudio: @unchecked Sendable {
    let player: AVAudioPlayer

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        self.player = player
    }
}

enum PlayQueue {
    static let restartThreshold: TimeInterval = 3
    static let historyLimit = 100

    static func previousRestarts(elapsed: TimeInterval) -> Bool { elapsed > restartThreshold }

    static func index(after current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let base = current ?? -delta
        return ((base + delta) % count + count) % count
    }

    static func shuffled(_ list: [Track], startingWith current: Track?) -> [Track] {
        var shuffled = list.shuffled()
        if let current, let position = shuffled.firstIndex(of: current) {
            shuffled.swapAt(0, position)
        }
        return shuffled
    }

    static func shuffleOrder(previous: [Track]?, natural: [Track], current: Track?) -> [Track] {
        guard let previous else { return shuffled(natural, startingWith: current) }
        let available = Set(natural.map(\.relativePath))
        var order = previous.filter { available.contains($0.relativePath) }
        let kept = Set(order.map(\.relativePath))
        order.append(contentsOf: natural.filter { !kept.contains($0.relativePath) }.shuffled())
        return order
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
