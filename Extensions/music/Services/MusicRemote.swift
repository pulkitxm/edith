import AppKit
import Combine
import EdithExtensionUI
import EdithExtensionSupport
import Observation
import SwiftUI

@MainActor
final class WindowVisibility: ObservableObject {
    static let shared = WindowVisibility()

    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func shutdown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func refresh() {
        let showing =
            !NSApp.isHidden
            && NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        if showing != visible { visible = showing }
    }
}

@MainActor
@Observable
final class MusicDetailPresenter {
    static let shared = MusicDetailPresenter()

    private(set) var track: Track?
    private(set) var beginRename = false
    private(set) var renameArmed = false
    private(set) var followsPlayback = false

    func show(_ track: Track, renaming: Bool = false) {
        beginRename = renaming
        renameArmed = false
        followsPlayback = MusicRemote.shared.currentFile == track.relativePath
        self.track = track
    }

    func armRename(_ value: Bool) {
        if renameArmed != value { renameArmed = value }
    }

    func followPlayback(_ track: Track) {
        guard self.track == track else { return }
        followsPlayback = true
    }

    func followCurrent() {
        guard followsPlayback, track != nil, let current = MusicRemote.shared.current,
            current != track
        else { return }
        beginRename = false
        renameArmed = false
        track = current
    }

    func dismiss() {
        track = nil
        beginRename = false
        renameArmed = false
        followsPlayback = false
    }
}

struct MusicListingCache: Sendable {
    var load: @Sendable (String) -> MusicLibraryContentListing?
    var save: @Sendable (String, MusicLibraryContentListing) -> Void

    static let empty = MusicListingCache(load: { _ in nil }, save: { _, _ in })

    static func disk() -> MusicListingCache {
        MusicListingCache(
            load: { MusicLibraryIndex.listing($0) },
            save: { path, listing in
                MusicLibraryIndex.storeListing(
                    path, folders: listing.folders.map(\.relativePath),
                    tracks: listing.tracks.map(\.relativePath))
            })
    }
}

@MainActor
@Observable
final class MusicRemote {
    static let shared: MusicRemote = {
        MusicLibraryIndex.activate()
        return MusicRemote(
            listingCache: .disk(),
            catalog: { TrackMeta.scanMusicFolder() })
    }()

    private(set) var tracks: [Track] = []
    private(set) var entriesLoaded = false
    private(set) var searchLoaded = false
    private(set) var favouritesLoaded = false
    private(set) var folderPath = ""
    private(set) var folders: [MusicFolder] = []
    private(set) var folderTracks: [Track] = []
    private(set) var searchTracks: [Track] = []
    private(set) var searchFolders: [MusicFolder] = []
    private(set) var favourites: [Track] = []
    private(set) var favouritePaths: Set<String> = []
    private(set) var showingFavourites = false
    private(set) var currentFile: String?
    private(set) var isPlaying = false
    private(set) var volume = 0.7 {
        didSet { videoSession?.applyVolume(volume) }
    }
    private(set) var looping = false
    private(set) var shuffling = false
    private(set) var duration: TimeInterval = 0
    private(set) var restorePending = SharedDefaults.store.integer(
        forKey: MusicBackupProvider.restorePendingKey)
    private(set) var libraryError: String?

    private var elapsedBase: TimeInterval = 0
    private var elapsedTimestamp: TimeInterval = 0
    private(set) var seekTick = 0
    private var stateObserver: NSObjectProtocol?
    private(set) var videoSession: VideoPreviewSession?
    private var videoResumesAudio = false
    private var levelObserver: NSObjectProtocol?
    private var levelPing: Timer?
    private var visibilityObserver: AnyCancellable?
    private var windowVisible = true

    var current: Track? {
        currentFile.map { Track(url: TrackMeta.url(for: $0), relativePath: $0) }
    }

    var elapsed: TimeInterval {
        _ = seekTick
        if let videoSession { return videoSession.elapsed }
        let raw =
            isPlaying
            ? elapsedBase + (Date().timeIntervalSince1970 - elapsedTimestamp) : elapsedBase
        return duration > 0 ? min(max(raw, 0), duration) : max(raw, 0)
    }

    var progress: Double { duration > 0 ? min(elapsed / duration, 1) : 0 }

    private var folderObserver: NSObjectProtocol?
    private var folderIPCObserver: NSObjectProtocol?
    private var revealObserver: NSObjectProtocol?
    private var searchScopePath: String?
    private var folderCache: [String: [MusicFolder]] = [:]
    private var favouritesTask: Task<Void, Never>?
    private var favouritesGeneration = 0
    private var catalogTask: Task<Void, Never>?
    private var entriesTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var catalogGeneration = 0
    private var entriesGeneration = 0
    private var searchGeneration = 0
    private var searchQuery = ""
    var searchDelay: Duration = .milliseconds(200)
    private let scanFavourites: @Sendable () -> [Track]
    private let listSubfolders: @Sendable (String) -> [MusicFolder]
    private let listFolder: @Sendable (String) -> MusicLibraryContentListing
    private let listingCache: MusicListingCache
    private let searchPage: @Sendable (String, String) -> MusicSearchPage
    private let searchRemainder: @Sendable (String, String) -> MusicSearchPage
    private let catalog: @Sendable () -> [Track]

    init(
        scanFavourites: @escaping @Sendable () -> [Track] = { Favourites.tracks() },
        listSubfolders: @escaping @Sendable (String) -> [MusicFolder] = {
            TrackMeta.subfolders(in: $0)
        },
        listFolder: @escaping @Sendable (String) -> MusicLibraryContentListing = { path in
            MusicLibraryContentOperationExecution.openFolder(path)
        },
        listingCache: MusicListingCache = .empty,
        searchPage: @escaping @Sendable (String, String) -> MusicSearchPage = { path, query in
            TrackMeta.searchPage(
                under: path, query: query, skip: 0, limit: MusicLibraryIndex.searchPageSize)
        },
        searchRemainder: @escaping @Sendable (String, String) -> MusicSearchPage = { path, query in
            TrackMeta.searchPage(
                under: path, query: query, skip: MusicLibraryIndex.searchPageSize, limit: nil)
        },
        catalog: @escaping @Sendable () -> [Track] = { [] }
    ) {
        self.scanFavourites = scanFavourites
        self.listSubfolders = listSubfolders
        self.listFolder = listFolder
        self.listingCache = listingCache
        self.searchPage = searchPage
        self.searchRemainder = searchRemainder
        self.catalog = catalog
    }

    func start() {
        if stateObserver != nil {
            rescan()
            return
        }
        stateObserver = MusicEvents.observe(
            MusicEvents.Name.musicState,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.apply(info) }
            })
        send(.status)
        folderObserver = NotificationCenter.default.addObserver(
            forName: .musicFolderChangedLocally, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        folderIPCObserver = MusicEvents.observe(MusicEvents.Name.musicFolderChanged) {
            [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        revealObserver = MusicEvents.observe(
            MusicEvents.Name.musicRevealFolder,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    guard let path = info["path"] as? String else { return }
                    _ = MusicReveal.consumePending()
                    self?.navigate(to: path)
                }
            })
        if let pending = MusicReveal.consumePending() { navigate(to: pending) }
        levelObserver = MusicEvents.observe(
            MusicEvents.Name.musicLevel,
            info: { info in
                MainActor.assumeIsolated {
                    guard let value = info["level"] as? Double else { return }
                    PlaybackLevel.shared.update(value)
                }
            })
        visibilityObserver = WindowVisibility.shared.$visible.sink { [weak self] visible in
            MainActor.assumeIsolated {
                self?.windowVisible = visible
                self?.refreshLevelPing()
            }
        }
        rescan()
    }

    private func refreshLevelPing() {
        let wanted = isPlaying && windowVisible && stateObserver != nil
        guard wanted != (levelPing != nil) else { return }
        guard wanted else {
            levelPing?.invalidate()
            levelPing = nil
            PlaybackLevel.shared.reset()
            return
        }
        MusicEvents.post(MusicEvents.Name.requestMusicLevels)
        levelPing = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MusicEvents.post(MusicEvents.Name.requestMusicLevels)
        }
        levelPing?.tolerance = 0.2
    }

    func stop() {
        videoSession?.stop(); videoSession = nil
        levelPing?.invalidate(); levelPing = nil
        favouritesTask?.cancel()
        favouritesTask = nil
        favouritesGeneration &+= 1
        favouritesLoaded = false
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration &+= 1
        entriesTask?.cancel()
        entriesTask = nil
        entriesGeneration &+= 1
        invalidateSearchScope()
        if let stateObserver {
            MusicEvents.stopObserving(stateObserver)
            self.stateObserver = nil
        }
        if let folderObserver {
            NotificationCenter.default.removeObserver(folderObserver)
            self.folderObserver = nil
        }
        if let folderIPCObserver {
            MusicEvents.stopObserving(folderIPCObserver)
            self.folderIPCObserver = nil
        }
        if let revealObserver {
            MusicEvents.stopObserving(revealObserver)
            self.revealObserver = nil
        }
        if let levelObserver {
            MusicEvents.stopObserving(levelObserver)
            self.levelObserver = nil
        }
        visibilityObserver = nil
        tracks = []
        entriesLoaded = false
        currentFile = nil
        isPlaying = false
        duration = 0
        refreshLevelPing()
    }

    func rescan() {
        refreshFavourites()
        folderCache.removeAll()
        let refreshSearch = !searchQuery.isEmpty
        invalidateSearchScope()
        if !folderPath.isEmpty,
            !FileManager.default.fileExists(atPath: TrackMeta.url(for: folderPath).path)
        {
            folderPath = ""
            entriesLoaded = false
        }
        restorePending = SharedDefaults.store.integer(forKey: MusicBackupProvider.restorePendingKey)
        refreshEntries()
        refreshCatalog()
        if refreshSearch { loadSearchScope() }
    }

    private func refreshCatalog() {
        catalogTask?.cancel()
        catalogGeneration &+= 1
        let generation = catalogGeneration
        let catalog = catalog
        catalogTask = Task { [weak self] in
            let scanned = await Task.detached { catalog() }.value
            guard !Task.isCancelled, let self, self.catalogGeneration == generation else { return }
            self.catalogTask = nil
            self.tracks = scanned
        }
    }

    private func refreshEntries() {
        entriesTask?.cancel()
        entriesGeneration &+= 1
        let generation = entriesGeneration
        let path = folderPath
        let listFolder = listFolder
        let listSubfolders = listSubfolders
        let listingCache = listingCache
        var ancestor = path
        var missingAncestors: [String] = []
        while !ancestor.isEmpty {
            let parent = (ancestor as NSString).deletingLastPathComponent
            guard parent != ancestor else { break }
            ancestor = parent
            if folderCache[ancestor] == nil { missingAncestors.append(ancestor) }
        }
        let ancestorPaths = missingAncestors
        entriesTask = Task { [weak self] in
            let cached = await Task.detached { listingCache.load(path) }.value
            if let cached, !Task.isCancelled, let self, self.entriesGeneration == generation,
                self.folderPath == path
            {
                self.folders = cached.folders
                self.folderTracks = cached.tracks
                self.entriesLoaded = true
                self.folderCache[path] = cached.folders
            }
            let result = await Task.detached {
                (
                    entries: listFolder(path),
                    ancestors: ancestorPaths.map { ($0, listSubfolders($0)) }
                )
            }.value
            guard !Task.isCancelled, let self, self.entriesGeneration == generation,
                self.folderPath == path
            else { return }
            let entries = result.entries
            self.entriesTask = nil
            self.folders = entries.folders
            self.folderTracks = entries.tracks
            self.entriesLoaded = true
            self.folderCache[path] = entries.folders
            for (ancestor, folders) in result.ancestors { self.folderCache[ancestor] = folders }
            await Task.detached { listingCache.save(path, entries) }.value
        }
    }

    func noteSearch(_ text: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchQuery = text
        guard !text.isEmpty else {
            invalidateSearchScope()
            return
        }
        let delay = searchDelay
        let query = text
        let path = folderPath
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.searchQuery == query, self.folderPath == path
            else { return }
            self.loadSearchScope(matching: query)
        }
    }

    func loadSearchScope() {
        loadSearchScope(matching: searchQuery)
    }

    func loadSearchScope(matching query: String) {
        let path = folderPath
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        searchScopePath = path
        searchLoaded = false
        let searchPage = searchPage
        let searchRemainder = searchRemainder
        searchTask = Task { [weak self] in
            let first = await Task.detached { searchPage(path, query) }.value
            guard !Task.isCancelled, let self, self.searchGeneration == generation,
                self.searchScopePath == path
            else { return }
            self.searchTracks = first.tracks
            self.searchFolders = first.folders
            self.searchLoaded = true
            let rest = await Task.detached { searchRemainder(path, query) }.value
            guard !Task.isCancelled, self.searchGeneration == generation,
                self.searchScopePath == path
            else { return }
            self.searchTask = nil
            self.searchTracks.append(contentsOf: rest.tracks)
            self.searchFolders.append(contentsOf: rest.folders)
        }
    }

    private func invalidateSearchScope() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        searchScopePath = nil
        searchLoaded = false
        searchTracks = []
        searchFolders = []
    }

    func subfolders(of path: String) -> [MusicFolder]? {
        folderCache[path]
    }

    func open(_ folder: MusicFolder) { navigate(to: folder.relativePath) }

    func navigate(to path: String) {
        showingFavourites = false
        if folderPath != path {
            entriesLoaded = false
            invalidateSearchScope()
        }
        folderPath = path
        refreshEntries()
    }

    func reveal(_ track: Track) {
        navigate(to: (track.relativePath as NSString).deletingLastPathComponent)
        SharedDefaults.store.set(
            "music", forKey: AppStorageKeys.General.mainWindowSection)
    }

    func openFavourites() {
        refreshFavourites()
        showingFavourites = true
    }

    private func refreshFavourites() {
        favouritesTask?.cancel()
        favouritesGeneration &+= 1
        let generation = favouritesGeneration
        let scanFavourites = scanFavourites
        favouritesTask = Task { [weak self] in
            let tracks = await Task.detached { scanFavourites() }.value
            guard !Task.isCancelled, let self, self.favouritesGeneration == generation else {
                return
            }
            self.favouritesTask = nil
            self.favourites = tracks
            self.favouritePaths = Set(tracks.map(\.relativePath))
            self.favouritesLoaded = true
        }
    }

    func toggleFavourite(_ track: Track) {
        let operation: MusicLibraryOperation =
            favouritePaths.contains(track.relativePath) ? .unfavorite : .favorite
        _ = MusicLibraryOperationExecution.setFavourite(operation, path: track.relativePath)
        if operation == .unfavorite {
            favouritePaths.remove(track.relativePath)
            favourites.removeAll { $0.relativePath == track.relativePath }
        } else {
            favouritePaths.insert(track.relativePath)
            favourites.append(track)
        }
        refreshFavourites()
    }

    func playFavourites() {
        send(.startSource(.favourites))
    }

    func playFolder(_ folder: MusicFolder) { playAll(under: folder.relativePath) }

    func playCurrentFolder() { playAll(under: folderPath) }

    private func playAll(under relativePath: String) {
        send(.startSource(.folder(relativePath)))
    }

    func apply(_ info: [AnyHashable: Any]) {
        let file = info["track"] as? String ?? ""
        let track = file.isEmpty ? nil : file
        if currentFile != track { currentFile = track }
        if let value = info["looping"] as? Bool, value != looping { looping = value }
        if let value = info["shuffling"] as? Bool, value != shuffling { shuffling = value }
        if let value = info["volume"] as? Double, value != volume { volume = value }
        guard let videoSession else {
            if let playing = info["isPlaying"] as? Bool, playing != isPlaying {
                isPlaying = playing
                refreshLevelPing()
            }
            if let value = info["duration"] as? Double, value != duration { duration = value }
            elapsedBase = info["elapsed"] as? Double ?? 0
            elapsedTimestamp = info["at"] as? Double ?? Date().timeIntervalSince1970
            return
        }
        if info["isPlaying"] as? Bool == true {
            pausePlayback()
            videoSession.toggle()
        }
    }

    func attachVideo(_ session: VideoPreviewSession, resumesAudio: Bool) {
        videoSession = session
        videoResumesAudio = resumesAudio
        session.applyVolume(volume)
        MusicDetailPresenter.shared.followPlayback(session.track)
        pausePlayback()
        isPlaying = session.isPlaying
        duration = session.duration
    }

    func detachVideo(_ session: VideoPreviewSession) {
        guard videoSession === session else { return }
        let position = session.elapsed
        let length = session.duration
        let resumes = videoResumesAudio
        let sameTrack = currentFile == session.track.relativePath
        videoSession = nil
        videoResumesAudio = false
        isPlaying = false
        if sameTrack, length > 0 { seek(to: position / length) }
        if resumes { resumePlayback() }
        send(.status)
    }

    func videoPlaybackChanged() {
        guard let videoSession else { return }
        if isPlaying != videoSession.isPlaying { isPlaying = videoSession.isPlaying }
        if duration != videoSession.duration { duration = videoSession.duration }
        seekTick += 1
    }

    private func leaveVideo() {
        guard let videoSession else { return }
        videoResumesAudio = false
        detachVideo(videoSession)
        if !MusicDetailPresenter.shared.followsPlayback {
            MusicDetailPresenter.shared.dismiss()
        }
    }

    private func send(_ request: MusicTransportRequest) {
        MusicTransportExecution.perform(
            request,
            sendCommand: { MusicEvents.post(MusicEvents.Name.musicCommand, userInfo: $0) },
            requestStatus: { MusicEvents.post(MusicEvents.Name.requestMusicState) })
    }

    private func sendLibraryChange(_ action: String, _ extra: [String: Any]) {
        var info: [String: Any] = ["action": action]
        info.merge(extra) { a, _ in a }
        MusicEvents.post(MusicEvents.Name.musicCommand, userInfo: info)
    }

    func toggle(_ track: Track) {
        if showingFavourites, currentFile != track.relativePath {
            send(.startSource(.favourites, start: track.relativePath))
            return
        }
        send(.startTrack(track.relativePath))
    }
    func playPause() {
        if let videoSession {
            videoSession.toggle()
            return
        }
        send(.toggle)
    }
    func pausePlayback() { send(.pause) }
    func resumePlayback() { send(.play) }
    func next() {
        leaveVideo()
        send(.next)
    }
    func previous() {
        leaveVideo()
        send(.previous)
    }
    func seek(to fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if let videoSession {
            videoSession.seek(toFraction: clamped)
            seekTick += 1
            return
        }
        if duration > 0 {
            elapsedBase = clamped * duration
            elapsedTimestamp = Date().timeIntervalSince1970
            seekTick += 1
        }
        send(.seek(clamped))
    }
    func setVolume(_ value: Double) {
        volume = value
        send(.volume(value))
    }
    func toggleLoop() { send(.repeat(!looping)) }
    func toggleShuffle() { send(.shuffle(!shuffling)) }

    func chooseLibrary(_ url: URL) {
        do {
            _ = try MusicFolderSelectionOperationExecution.select(url.path)
            libraryError = nil
            rescan()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func dismissLibraryError() {
        libraryError = nil
    }

    private func libraryResult<T>(_ perform: () throws -> T) -> T? {
        do {
            return try perform()
        } catch {
            libraryError = error.localizedDescription
            return nil
        }
    }

    func delete(_ track: Track) {
        libraryError = nil
        guard
            libraryResult({
                try MusicLibraryContentOperationExecution.remove(.track(track))
            }) != nil
        else { return }
        rescan()
        broadcastFolderChanged()
    }

    func rename(_ track: Track, to name: String) {
        libraryError = nil
        guard
            let move = libraryResult({
                try MusicLibraryContentOperationExecution.rename(.track(track), to: name)
            })
        else { return }
        sendLibraryChange("renamed", ["from": move.from, "to": move.to])
        refreshAfterFileChange()
    }

    private func sanitizedName(_ name: String) -> String {
        MusicLibrary.sanitized(name)
    }

    private func refreshAfterFileChange() {
        rescan()
        broadcastFolderChanged()
    }

    func createFolder(named name: String) {
        libraryError = nil
        guard
            libraryResult({
                try MusicLibraryContentOperationExecution.createFolder(
                    named: name, under: folderPath)
            }) != nil
        else {
            return
        }
        refreshEntries()
        broadcastFolderChanged()
    }

    func move(_ track: Track, toFolderPath folderRelativePath: String) {
        libraryError = nil
        if moveTrack(track, toFolderPath: folderRelativePath) { refreshAfterFileChange() }
    }

    func move(relativePaths: [String], toFolderPath folderRelativePath: String) {
        libraryError = nil
        var moved = false
        for path in relativePaths {
            let track = Track(url: TrackMeta.url(for: path), relativePath: path)
            moved = moveTrack(track, toFolderPath: folderRelativePath) || moved
        }
        if moved { refreshAfterFileChange() }
    }

    private func moveTrack(_ track: Track, toFolderPath folderRelativePath: String) -> Bool {
        guard
            let move = libraryResult({
                try MusicLibraryContentOperationExecution.move(track, to: folderRelativePath)
            })
        else {
            return false
        }
        sendLibraryChange("renamed", ["from": move.from, "to": move.to])
        return true
    }

    func renameFolder(_ folder: MusicFolder, to name: String) {
        libraryError = nil
        guard sanitizedName(name) != folder.name,
            let renamed = libraryResult({
                try MusicLibraryContentOperationExecution.rename(.folder(folder), to: name)
            })
        else { return }
        let newPath = renamed.to
        if let playing = currentFile,
            playing == folder.relativePath || playing.hasPrefix(folder.relativePath + "/")
        {
            sendLibraryChange(
                "renamed",
                ["from": playing, "to": newPath + playing.dropFirst(folder.relativePath.count)])
        }
        repointFolderPath(from: folder.relativePath, to: newPath)
        rescan()
        broadcastFolderChanged()
    }

    func deleteFolder(_ folder: MusicFolder) {
        libraryError = nil
        guard
            libraryResult({
                try MusicLibraryContentOperationExecution.remove(.folder(folder))
            }) != nil
        else { return }
        repointFolderPath(from: folder.relativePath, to: nil)
        rescan()
        broadcastFolderChanged()
    }

    private func repointFolderPath(from old: String, to new: String?) {
        guard folderPath == old || folderPath.hasPrefix(old + "/") else { return }
        if let new {
            folderPath = new + folderPath.dropFirst(old.count)
        } else {
            folderPath = (old as NSString).deletingLastPathComponent
        }
    }

    private func broadcastFolderChanged() {
        TrackMeta.invalidateCaches()
        folderCache.removeAll()
        NotificationCenter.default.post(name: .musicFolderChangedLocally, object: nil)
        MusicEvents.post(MusicEvents.Name.musicFolderChanged)
    }

    func nudgeSeek(_ seconds: TimeInterval) {
        guard duration > 0 else { return }
        let target = min(max(elapsed + seconds, 0), duration)
        seek(to: target / duration)
    }

    func nudgeVolume(_ delta: Double) {
        setVolume(min(max(volume + delta, 0), 1))
    }
}
