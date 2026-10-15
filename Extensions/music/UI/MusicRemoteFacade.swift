import AppKit
import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class EmbeddedMusicRemote {
    static let shared = EmbeddedMusicRemote()
    static let searchPageSize = 40
    private(set) var tracks: [EmbeddedTrack] = []
    private(set) var entriesLoaded = false
    private(set) var searchLoaded = false
    private(set) var catalogLoaded = false
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
    @ObservationIgnored private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var catalogGeneration: UInt64 = 0
    @ObservationIgnored private var listingGeneration: UInt64 = 0
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored var searchDelay: Duration = .milliseconds(200)
    @ObservationIgnored private var retiredClients: [RetiredClient] = []
    private struct RetiredClient {
        weak var value: ExtensionEngineClient?
    }
    private var suspended = false
    private var configurationAfterStop = false
    private var generation: UInt64 = 0
    private var query = ""
    private var lifecycle: UInt64 = 0
    private var cursor = 0
    private var folderIntentRevision: UInt64 = 0
    private var readQuery: EmbeddedMusicUIQuery?
    private var folderCache: [String: [EmbeddedMusicFolder]] = [:]

    var current: EmbeddedTrack? {
        currentFile.map {
            EmbeddedTrack(url: EmbeddedTrackMeta.url(for: $0), relativePath: $0)
        }
    }
    var elapsed: Double {
        min(duration, max(0, elapsedBase + (isPlaying ? Date().timeIntervalSince(sampledAt) : 0)))
    }
    var progress: Double { duration > 0 ? elapsed / duration : 0 }

    func configure(_ client: ExtensionEngineClient) {
        retiredClients.removeAll { $0.value == nil }
        guard !retiredClients.contains(where: { $0.value === client }), admitConfiguration() else {
            return
        }
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
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        retire(client)
        if clients.isEmpty { stop() }
    }

    func configure(invoke: @escaping (String, Data) async throws -> Data) {
        guard admitConfiguration() else { return }
        stop(); self.invoke = invoke; installLevelDemand()
    }

    private func admitConfiguration() -> Bool {
        guard stopTask == nil else { return false }
        if suspended {
            guard configurationAfterStop else { return false }
            suspended = false
            configurationAfterStop = false
        }
        return true
    }

    private func retire(_ client: ExtensionEngineClient) {
        client.invalidate()
        retiredClients.append(RetiredClient(value: client))
    }

    func start() {
        rescan()
        if !entriesLoaded { showCachedListing() }
    }

    private func ownedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>
    {
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.ownedTasks[id] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
        ownedTasks[id] = task
        return task
    }

    func suspendCommands() {
        suspended = true
        configurationAfterStop = false
        generation &+= 1; lifecycle &+= 1; levelGeneration &+= 1
        EmbeddedPlaybackLevel.shared.onViewersChange = nil
        for task in ownedTasks.values { task.cancel() }
    }

    func suspendCommandsAndWait() async {
        suspendCommands()
        let owned = Array(ownedTasks.values)
        for task in owned { await task.value }
    }

    func stopAndWait() async {
        if let stopTask { await stopTask.value; return }
        suspendCommands()
        stop()
        let owned = Array(ownedTasks.values)
        let token = lifecycle
        let task = Task { [weak self] in
            for task in owned { await task.value }
            guard let self else { return }
            if self.lifecycle == token { self.configurationAfterStop = true }
            self.stopTask = nil
        }
        stopTask = task
        await task.value
    }

    func stop() {
        EmbeddedMusicBrowserSession.stopAll()
        EmbeddedMusicVideoSession.stopAll()
        generation &+= 1; lifecycle &+= 1; cursor = 0
        folderIntentRevision = 0
        readTask?.cancel(); readTask = nil
        levelGeneration &+= 1; levelTask?.cancel(); levelTask = nil
        EmbeddedPlaybackLevel.shared.onViewersChange = nil
        EmbeddedPlaybackLevel.shared.reset()
        for task in ownedTasks.values { task.cancel() }
        tasks.removeAll()
        catalogTask = nil; searchTask = nil; searchDebounceTask = nil
        catalogGeneration &+= 1; listingGeneration &+= 1; searchGeneration &+= 1
        for client in clients.values { retire(client) }
        clients.removeAll(); invoke = nil
        tracks = []; folders = []; folderTracks = []; searchTracks = []; searchFolders = []
        favourites = []; favouritePaths = []; currentFile = nil; isPlaying = false
        elapsedBase = 0; sampledAt = Date(); duration = 0; volume = 0.7
        looping = false; shuffling = false; restorePending = 0; showingFavourites = false
        folderPath = ""; query = ""; readQuery = nil; libraryError = nil
        EmbeddedMusicTools.shared.installed = []; EmbeddedMusicTools.shared.installing = nil
        EmbeddedMusicTools.shared.error = nil
        entriesLoaded = false; searchLoaded = false; favouritesLoaded = false
        catalogLoaded = false
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
        guard !suspended, invoke != nil, EmbeddedPlaybackLevel.shared.viewers > 0 else {
            levelGeneration &+= 1; levelTask?.cancel(); levelTask = nil
            return
        }
        guard levelTask == nil else { return }
        levelGeneration &+= 1
        let token = levelGeneration
        levelTask = ownedTask { [weak self] in
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
        guard !suspended, let invoke else { return }
        let request = EmbeddedMusicUIQuery(path: folderPath, cursor: cursor)
        if !force, readTask != nil, readQuery == request { return }
        readTask?.cancel(); generation &+= 1
        let token = generation
        readQuery = request
        readTask = ownedTask { [weak self] in
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
        let nextFolders = value.folders.map(folder)
        let nextTracks = value.folderTracks.map(track)
        let listingChanged = entriesLoaded && (folders != nextFolders || folderTracks != nextTracks)
        folders = nextFolders; folderTracks = nextTracks; favourites = value.favourites.map(track)
        favouritePaths = Set(favourites.map(\.relativePath))
        currentFile = value.playback.path; isPlaying = value.playback.playing
        elapsedBase = value.playback.elapsed; sampledAt = Date(); duration = value.playback.duration
        volume = value.playback.volume; shuffling = value.playback.shuffle;
        looping = value.playback.repeating
        restorePending = value.restorePending
        entriesLoaded = true; favouritesLoaded = true
        folderCache[folderPath] = folders
        EmbeddedMusicVideoSession.apply(value.videoControl)
        EmbeddedMusicAccounts.shared.apply(value)
        let tools = EmbeddedMusicTools.shared
        tools.installed = value.tools.installed; tools.installing = value.tools.installing;
        tools.error = value.tools.error
        applyPreferences(value.preferences)

        cursor = value.cursor
        if listingChanged, catalogLoaded { refreshCatalog() }
        EmbeddedMusicPrivacyState.shared.active = value.privacy
        for event in value.events {
            if let object = try? JSONSerialization.jsonObject(with: event.data) as? [String: Any] {
                EmbeddedMusicAccounts.shared.spotify.library.apply(object)
            }
        }
        if let intent = value.folderIntent, intent.revision > folderIntentRevision {
            folderIntentRevision = intent.revision
            let changed = folderPath != intent.path || showingFavourites || !query.isEmpty
            folderPath = intent.path; showingFavourites = false
            if changed {
                folders = []; folderTracks = []
                entriesLoaded = false
                clearSearch()
                rescan()
                showCachedListing()
            }
        }
    }

    func applyPreferences(_ preferences: EmbeddedMusicUIPreferences) {
        let defaults = SharedDefaults.store
        for (key, next) in [
            (EmbeddedMusicFade.enabledKey, preferences.crossfade),
            (AppStorageKeys.Music.barCollapsed, preferences.barCollapsed),
            (AppStorageKeys.Music.barAutoHide, preferences.barAutoHide),
            (AppStorageKeys.Music.gridView, preferences.gridView),
        ] where defaults.object(forKey: key) as? Bool != next { defaults.set(next, forKey: key) }
        if defaults.double(forKey: EmbeddedMusicFade.secondsKey) != preferences.fadeLength {
            defaults.set(preferences.fadeLength, forKey: EmbeddedMusicFade.secondsKey)
        }

    }

    func dataRequest(_ operation: String, payload: Data = Data("{}".utf8)) async throws -> Data {
        guard !suspended, let invoke else { throw ExtensionPeerError.unavailable }
        let token = lifecycle
        let result = try await invoke(operation, payload)
        try Task.checkCancellation()
        guard self.invoke != nil, lifecycle == token else { throw CancellationError() }
        return result
    }

    func request(_ operation: String, action: EmbeddedMusicUIAction) async throws -> Data {
        guard !suspended, let invoke else { throw ExtensionPeerError.unavailable }
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
        guard !suspended, invoke != nil else { return }
        let id = UUID()
        tasks[id] = ownedTask { [weak self] in
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
        guard !suspended, let invoke,
            let payload = try? JSONSerialization.data(withJSONObject: command)
        else {
            return
        }
        let id = UUID()
        let token = lifecycle
        tasks[id] = ownedTask { [weak self] in
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
        guard !suspended, let invoke else { throw ExtensionPeerError.unavailable }
        let token = lifecycle
        let data = try await invoke("music.ui.streamingArtwork", JSONEncoder().encode(url))
        try Task.checkCancellation()
        guard lifecycle == token else { throw CancellationError() }
        return try JSONDecoder().decode(Data.self, from: data)
    }

    func profiles() async throws -> [EmbeddedChromeProfile] {
        guard !suspended, let invoke else { throw ExtensionPeerError.unavailable }
        let token = lifecycle
        let data = try await invoke("music.ui.profiles", Data("{}".utf8))
        try Task.checkCancellation()
        guard token == lifecycle else { throw CancellationError() }
        return try JSONDecoder().decode([EmbeddedMusicUIProfile].self, from: data).map {
            .init(id: $0.id, name: $0.name)
        }
    }
    func noteSearch(_ text: String) {
        searchDebounceTask?.cancel(); searchDebounceTask = nil
        query = text
        guard !text.isEmpty else { clearSearch(); return }
        guard !suspended, invoke != nil else { return }
        let delay = searchDelay
        let path = folderPath
        searchDebounceTask = ownedTask { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.query == text, self.folderPath == path else { return }
            self.searchDebounceTask = nil
            self.loadSearch(matching: text)
        }
    }

    func loadCatalog() {
        guard !catalogLoaded, catalogTask == nil else { return }
        refreshCatalog()
    }

    private func clearSearch() {
        searchDebounceTask?.cancel(); searchDebounceTask = nil
        searchTask?.cancel(); searchTask = nil
        searchGeneration &+= 1
        query = ""
        searchTracks = []; searchFolders = []; searchLoaded = false
    }

    private func refreshCatalog() {
        guard !suspended, invoke != nil else { return }
        catalogTask?.cancel()
        catalogGeneration &+= 1
        let token = catalogGeneration
        catalogTask = ownedTask { [weak self] in
            guard let self else { return }
            defer { if self.catalogGeneration == token { self.catalogTask = nil } }
            guard let data = try? await self.dataRequest("music.ui.catalog"),
                let entries = try? JSONDecoder().decode([EmbeddedMusicUIEntry].self, from: data),
                (try? EmbeddedMusicUIListing(folders: [], tracks: entries).validate()) != nil,
                !Task.isCancelled, self.catalogGeneration == token
            else { return }
            self.tracks = entries.map { .init(url: $0.url, relativePath: $0.path) }
            self.catalogLoaded = true
        }
    }

    private func showCachedListing() {
        guard !suspended, invoke != nil else { return }
        let path = folderPath
        listingGeneration &+= 1
        let token = listingGeneration
        let lifecycleToken = lifecycle
        _ = ownedTask { [weak self] in
            guard let self,
                let data = try? await self.dataRequest(
                    "music.ui.cachedListing",
                    payload: JSONEncoder().encode(EmbeddedMusicUIQuery(path: path))),
                let cached = try? JSONDecoder().decode(EmbeddedMusicUIListing?.self, from: data),
                (try? cached.validate()) != nil,
                !Task.isCancelled, self.listingGeneration == token,
                self.lifecycle == lifecycleToken,
                self.folderPath == path, !self.entriesLoaded
            else { return }
            self.folders = cached.folders.map { .init(url: $0.url, relativePath: $0.path) }
            self.folderTracks = cached.tracks.map { .init(url: $0.url, relativePath: $0.path) }
            self.folderCache[path] = self.folders
            self.entriesLoaded = true
        }
    }

    private func loadSearch(matching text: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let token = searchGeneration
        let path = folderPath
        let pageSize = EmbeddedMusicRemote.searchPageSize
        searchTask = ownedTask { [weak self] in
            guard let self else { return }
            defer { if self.searchGeneration == token { self.searchTask = nil } }
            guard
                let first = await self.searchPage(
                    path: path, text: text, skip: 0, limit: pageSize),
                !Task.isCancelled, self.searchGeneration == token
            else { return }
            self.searchTracks = first.tracks.map { .init(url: $0.url, relativePath: $0.path) }
            self.searchFolders = first.folders.map { .init(url: $0.url, relativePath: $0.path) }
            self.searchLoaded = true
            guard
                let rest = await self.searchPage(
                    path: path, text: text, skip: pageSize, limit: nil),
                !Task.isCancelled, self.searchGeneration == token
            else { return }
            self.searchTracks += rest.tracks.map { .init(url: $0.url, relativePath: $0.path) }
            self.searchFolders += rest.folders.map { .init(url: $0.url, relativePath: $0.path) }
        }
    }

    private func searchPage(path: String, text: String, skip: Int, limit: Int?) async
        -> EmbeddedMusicUIListing?
    {
        let request = EmbeddedMusicUISearchRequest(
            path: path, search: text, skip: skip, limit: limit)
        guard let payload = try? JSONEncoder().encode(request),
            let data = try? await dataRequest("music.ui.search", payload: payload),
            let page = try? JSONDecoder().decode(EmbeddedMusicUIListing.self, from: data),
            (try? page.validate()) != nil
        else { return nil }
        return page
    }
    func subfolders(of path: String) -> [EmbeddedMusicFolder]? { folderCache[path] }
    func open(_ folder: EmbeddedMusicFolder) { navigate(to: folder.relativePath) }
    func navigate(to path: String) {
        showingFavourites = false
        let moved = folderPath != path
        if moved {
            entriesLoaded = false
            clearSearch()
        }
        folderPath = path
        rescan()
        if moved { showCachedListing() }
    }
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
