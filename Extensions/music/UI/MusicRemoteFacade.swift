import AppKit
import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class EmbeddedMusicRemote {
    static let shared = EmbeddedMusicRemote()
    private(set) var tracks: [EmbeddedTrack] = []
    private(set) var entriesLoaded = false
    private(set) var searchLoaded = false
    private(set) var favouritesLoaded = false
    private(set) var folderPath = ""
    private(set) var folders: [EmbeddedMusicFolder] = []
    private(set) var folderTracks: [EmbeddedTrack] = []
    private(set) var searchTracks: [EmbeddedTrack] = []
    private(set) var searchFolders: [EmbeddedMusicFolder] = []
    private(set) var favourites: [EmbeddedTrack] = []
    private(set) var favouritePaths: Set<String> = []
    private(set) var showingFavourites = false
    private(set) var currentFile: String?
    private(set) var isPlaying = false
    private(set) var volume = 0.7
    private(set) var looping = false
    private(set) var shuffling = false
    private(set) var duration = 0.0
    private(set) var restorePending = 0
    private(set) var libraryError: String?
    private var elapsedBase = 0.0
    private var sampledAt = Date()
    @ObservationIgnored private var clients: [ObjectIdentifier: ExtensionEngineClient] = [:]
    @ObservationIgnored private var invoke: ((String, Data) async throws -> Data)?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var levelGeneration: UInt64 = 0
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    private var query = ""
    private var lifecycle: UInt64 = 0
    private var cursor = 0
    private var folderIntentRevision: UInt64 = 0
    private var readQuery: EmbeddedMusicUIQuery?
    private var folderCache: [String: [EmbeddedMusicFolder]] = [:]

    var current: EmbeddedTrack? { tracks.first { $0.relativePath == currentFile } }
    var elapsed: Double {
        min(duration, max(0, elapsedBase + (isPlaying ? Date().timeIntervalSince(sampledAt) : 0)))
    }
    var progress: Double { duration > 0 ? elapsed / duration : 0 }

    func configure(_ client: ExtensionEngineClient) {
        clients[ObjectIdentifier(client)] = client
        invoke = { [weak self] operation, payload in
            guard let client = self?.clients.values.first else {
                throw ExtensionPeerError.unavailable
            }
            return try await client.invoke(operation, payload: payload)
        }
        installLevelDemand()
    }

    func detach(_ client: ExtensionEngineClient) {
        clients[ObjectIdentifier(client)] = nil
        client.invalidate()
        if clients.isEmpty { stop() }
    }

    func configure(invoke: @escaping (String, Data) async throws -> Data) {
        stop(); self.invoke = invoke; installLevelDemand()
    }

    func start() { rescan() }

    func stop() {
        EmbeddedMusicVideoSession.stopAll()
        generation &+= 1; lifecycle &+= 1; cursor = 0
        folderIntentRevision = 0
        readTask?.cancel(); readTask = nil
        levelGeneration &+= 1; levelTask?.cancel(); levelTask = nil
        EmbeddedPlaybackLevel.shared.onViewersChange = nil
        EmbeddedPlaybackLevel.shared.reset()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for client in clients.values { client.invalidate() }
        clients.removeAll(); invoke = nil
        tracks = []; folders = []; folderTracks = []; searchTracks = []; searchFolders = []
        favourites = []; favouritePaths = []; currentFile = nil; isPlaying = false
        elapsedBase = 0; sampledAt = Date(); duration = 0; volume = 0.7
        looping = false; shuffling = false; restorePending = 0; showingFavourites = false
        folderPath = ""; query = ""; readQuery = nil; libraryError = nil
        EmbeddedMusicTools.shared.installed = []; EmbeddedMusicTools.shared.installing = nil
        EmbeddedMusicTools.shared.error = nil
        entriesLoaded = false; searchLoaded = false; favouritesLoaded = false
        folderCache.removeAll(); EmbeddedTrackMeta.clear()
        EmbeddedMusicAccounts.shared.reset()
        EmbeddedMusicDetailPresenter.shared.dismiss()
        EmbeddedYoutubeDownloader.shared.stop()
    }

    private func installLevelDemand() {
        EmbeddedPlaybackLevel.shared.onViewersChange = { [weak self] in self?.refreshLevels() }
        refreshLevels()
    }

    private func refreshLevels() {
        guard invoke != nil, EmbeddedPlaybackLevel.shared.viewers > 0 else {
            levelGeneration &+= 1; levelTask?.cancel(); levelTask = nil
            return
        }
        guard levelTask == nil else { return }
        levelGeneration &+= 1
        let token = levelGeneration
        levelTask = Task { [weak self] in
            defer { if self?.levelGeneration == token { self?.levelTask = nil } }
            while !Task.isCancelled, let self, self.levelGeneration == token,
                EmbeddedPlaybackLevel.shared.viewers > 0
            {
                do {
                    let data = try await self.dataRequest("music.ui.level")
                    let level = try JSONDecoder().decode(Double.self, from: data)
                    guard level.isFinite, (0...1).contains(level) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    try Task.checkCancellation()
                    guard self.levelGeneration == token else { return }
                    EmbeddedPlaybackLevel.shared.update(level)
                } catch {
                    guard !Task.isCancelled, self.levelGeneration == token else { return }
                    self.libraryError = error.localizedDescription
                }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }

    func rescan(force: Bool = false) {
        guard let invoke else { return }
        let request = EmbeddedMusicUIQuery(path: folderPath, search: query, cursor: cursor)
        if !force, readTask != nil, readQuery == request { return }
        readTask?.cancel(); generation &+= 1
        let token = generation
        readQuery = request
        readTask = Task { [weak self] in
            defer {
                if let self, self.generation == token { self.readTask = nil; self.readQuery = nil }
            }
            do {
                let data = try await invoke("music.ui.read", JSONEncoder().encode(request))
                let value = try JSONDecoder().decode(EmbeddedMusicUIState.self, from: data)
                try value.validate()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.apply(value)
                self.libraryError = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.libraryError = error.localizedDescription
            }
        }
    }

    private func apply(_ value: EmbeddedMusicUIState) {
        func track(_ entry: EmbeddedMusicUIEntry) -> EmbeddedTrack {
            .init(url: entry.url, relativePath: entry.path)
        }
        func folder(_ entry: EmbeddedMusicUIEntry) -> EmbeddedMusicFolder {
            .init(url: entry.url, relativePath: entry.path)
        }
        EmbeddedTrackMeta.root = value.root
        tracks = value.tracks.map(track); folders = value.folders.map(folder)
        folderTracks = value.folderTracks.map(track); searchTracks = value.searchTracks.map(track)
        searchFolders = value.searchFolders.map(folder); favourites = value.favourites.map(track)
        favouritePaths = Set(favourites.map(\.relativePath))
        currentFile = value.playback.path; isPlaying = value.playback.playing
        elapsedBase = value.playback.elapsed; sampledAt = Date(); duration = value.playback.duration
        volume = value.playback.volume; shuffling = value.playback.shuffle;
        looping = value.playback.repeating
        restorePending = value.restorePending
        entriesLoaded = true; searchLoaded = true; favouritesLoaded = true
        folderCache[folderPath] = folders
        EmbeddedMusicVideoSession.apply(value.videoControl)
        EmbeddedMusicAccounts.shared.apply(value)
        let tools = EmbeddedMusicTools.shared
        tools.installed = value.tools.installed; tools.installing = value.tools.installing;
        tools.error = value.tools.error
        let defaults = SharedDefaults.store
        for (key, next) in [
            (EmbeddedMusicFade.enabledKey, value.preferences.crossfade),
            (AppStorageKeys.Music.barCollapsed, value.preferences.barCollapsed),
            (AppStorageKeys.Music.barAutoHide, value.preferences.barAutoHide),
            (AppStorageKeys.Music.gridView, value.preferences.gridView),
        ] where defaults.object(forKey: key) as? Bool != next { defaults.set(next, forKey: key) }
        if defaults.double(forKey: EmbeddedMusicFade.secondsKey) != value.preferences.fadeLength {
            defaults.set(value.preferences.fadeLength, forKey: EmbeddedMusicFade.secondsKey)
        }

        cursor = value.cursor
        EmbeddedMusicPrivacyState.shared.active = value.privacy
        for event in value.events {
            if let object = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any] {
                EmbeddedMusicAccounts.shared.spotify.library.apply(object)
            }
        }
        if let intent = value.folderIntent, intent.revision > folderIntentRevision {
            folderIntentRevision = intent.revision
            let changed = folderPath != intent.path || showingFavourites || !query.isEmpty
            folderPath = intent.path; showingFavourites = false; query = ""
            if changed {
                folders = []; folderTracks = []; searchTracks = []; searchFolders = []
                entriesLoaded = false; searchLoaded = false
                rescan()
            }
        }
    }

    func dataRequest(_ operation: String, payload: Data = Data("{}".utf8)) async throws -> Data {
        guard let invoke else { throw ExtensionPeerError.unavailable }
        let token = lifecycle
        let result = try await invoke(operation, payload)
        try Task.checkCancellation()
        guard self.invoke != nil, lifecycle == token else { throw CancellationError() }
        return result
    }

    func request(_ operation: String, action: EmbeddedMusicUIAction) async throws -> Data {
        guard let invoke else { throw ExtensionPeerError.unavailable }
        try action.validate()
        let token = lifecycle
        let result = try await invoke(operation, JSONEncoder().encode(action))
        try Task.checkCancellation()
        guard self.invoke != nil, lifecycle == token else { throw CancellationError() }
        return result
    }

    func send(
        _ kind: EmbeddedMusicUIActionKind, path: String = "", target: String = "",
        value: Double? = nil
    ) {
        guard invoke != nil else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do {
                _ = try await self.request(
                    "music.ui.action",
                    action: .init(kind: kind, path: path, target: target, value: value))
                self.rescan(force: true)
            } catch {
                if !Task.isCancelled { self.libraryError = error.localizedDescription }
            }
        }
    }

    func streaming(_ action: String) { spotify(["action": action]) }
    func spotify(_ command: [String: Any]) {
        guard let invoke, let payload = try? JSONSerialization.data(withJSONObject: command) else {
            return
        }
        let id = UUID()
        let token = lifecycle
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            do {
                _ = try await invoke("music.ui.spotify", payload)
                guard !Task.isCancelled, let self, self.lifecycle == token else { return }
                self.rescan()
            } catch {
                if !Task.isCancelled, self?.lifecycle == token {
                    self?.libraryError = error.localizedDescription
                }
            }
        }
    }
    func streamingArtwork(_ url: URL) async throws -> Data {
        guard let invoke else { throw ExtensionPeerError.unavailable }
        let token = lifecycle
        let data = try await invoke("music.ui.streamingArtwork", JSONEncoder().encode(url))
        try Task.checkCancellation()
        guard lifecycle == token else { throw CancellationError() }
        return try JSONDecoder().decode(Data.self, from: data)
    }

    func profiles() async throws -> [EmbeddedChromeProfile] {
        guard let invoke else { throw ExtensionPeerError.unavailable }
        let token = lifecycle
        let data = try await invoke("music.ui.profiles", Data("{}".utf8))
        try Task.checkCancellation()
        guard token == lifecycle else { throw CancellationError() }
        return try JSONDecoder().decode([EmbeddedMusicUIProfile].self, from: data).map {
            .init(id: $0.id, name: $0.name)
        }
    }
    func youtubeFrame(width: Double, height: Double) async -> NSImage? {
        guard let invoke else { return nil }
        let token = lifecycle
        guard
            let payload = try? JSONEncoder().encode(
                EmbeddedMusicUIFrameRequest(
                    width: max(100, min(2560, width)), height: max(100, min(1440, height)))),
            let data = try? await invoke("music.ui.youtube.frame", payload),
            !Task.isCancelled, lifecycle == token,
            let bytes = try? JSONDecoder().decode(Data.self, from: data), bytes.count <= 1_048_576
        else { return nil }
        return NSImage(data: bytes)
    }

    func noteSearch(_ text: String) { query = text; rescan() }
    func subfolders(of path: String) -> [EmbeddedMusicFolder]? { folderCache[path] }
    func open(_ folder: EmbeddedMusicFolder) { navigate(to: folder.relativePath) }
    func navigate(to path: String) { folderPath = path; showingFavourites = false; rescan() }
    func reveal(_ track: EmbeddedTrack) {
        let path = (track.relativePath as NSString).deletingLastPathComponent
        send(.openMusic, path: path, target: "folder")
    }
    func openFavourites() { showingFavourites = true; rescan() }
    func toggleFavourite(_ track: EmbeddedTrack) { send(.favourite, path: track.relativePath) }
    func playFavourites() { send(.startFavourites) }
    func playFolder(_ folder: EmbeddedMusicFolder) { send(.startFolder, path: folder.relativePath) }
    func playCurrentFolder() { send(.startFolder, path: folderPath) }
    func toggle(_ track: EmbeddedTrack) {
        send(showingFavourites ? .startFavourites : .startTrack, path: track.relativePath)
    }
    func playPause() { send(.playPause) }
    func pausePlayback() { send(.pause) }
    func resumePlayback() { send(.resume) }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func seek(to fraction: Double) { send(.seek, value: min(max(fraction, 0), 1)) }
    func setVolume(_ value: Double) { send(.volume, value: min(max(value, 0), 1)) }
    func toggleLoop() { send(.repeating) }
    func toggleShuffle() { send(.shuffle) }
    func chooseLibrary() { send(.chooseLibrary) }
    func openLibrary() { send(.openLibrary) }
    func openDownloads() { send(.openDownloads) }
    func dismissLibraryError() { libraryError = nil }
    func delete(_ track: EmbeddedTrack) { send(.delete, path: track.relativePath) }
    func rename(_ track: EmbeddedTrack, to name: String) {
        send(.rename, path: track.relativePath, target: name)
    }
    func createFolder(named name: String) { send(.createFolder, path: folderPath, target: name) }
    func move(_ track: EmbeddedTrack, toFolderPath path: String) {
        send(.move, path: track.relativePath, target: path)
    }
    func move(relativePaths: [String], toFolderPath path: String) {
        for source in relativePaths { send(.move, path: source, target: path) }
    }
    func renameFolder(_ folder: EmbeddedMusicFolder, to name: String) {
        send(.renameFolder, path: folder.relativePath, target: name)
    }
    func deleteFolder(_ folder: EmbeddedMusicFolder) {
        send(.deleteFolder, path: folder.relativePath)
    }
    func nudgeSeek(_ seconds: TimeInterval) {
        guard duration > 0 else { return }; seek(to: (elapsed + seconds) / duration)
    }
    func nudgeVolume(_ delta: Double) { setVolume(volume + delta) }
}
