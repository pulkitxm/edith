import AppKit
import Combine
import EdithKit
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

@MainActor
@Observable
final class MusicRemote {
    static let shared = MusicRemote()

    private(set) var tracks: [Track] = []
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
        forKey: "restorePending.music")

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

    func start() {
        if stateObserver != nil {
            rescan()
            return
        }
        stateObserver = IPC.observe(
            IPC.Name.musicState,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.apply(info) }
            })
        IPC.post(IPC.Name.requestMusicState)
        folderObserver = NotificationCenter.default.addObserver(
            forName: .musicFolderChangedLocally, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        folderIPCObserver = IPC.observe(IPC.Name.musicFolderChanged) { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        revealObserver = IPC.observe(
            IPC.Name.musicRevealFolder,
            info: { [weak self] info in
                MainActor.assumeIsolated {
                    guard let path = info["path"] as? String else { return }
                    _ = MusicReveal.consumePending()
                    self?.navigate(to: path)
                }
            })
        if let pending = MusicReveal.consumePending() { navigate(to: pending) }
        levelObserver = IPC.observe(
            IPC.Name.musicLevel,
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
        IPC.post(IPC.Name.requestMusicLevels)
        levelPing = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            IPC.post(IPC.Name.requestMusicLevels)
        }
        levelPing?.tolerance = 0.2
    }

    func stop() {
        if let stateObserver {
            IPC.stopObserving(stateObserver)
            self.stateObserver = nil
        }
        if let folderObserver {
            NotificationCenter.default.removeObserver(folderObserver)
            self.folderObserver = nil
        }
        if let folderIPCObserver {
            IPC.stopObserving(folderIPCObserver)
            self.folderIPCObserver = nil
        }
        if let revealObserver {
            IPC.stopObserving(revealObserver)
            self.revealObserver = nil
        }
        if let levelObserver {
            IPC.stopObserving(levelObserver)
            self.levelObserver = nil
        }
        visibilityObserver = nil
        tracks = []
        currentFile = nil
        isPlaying = false
        duration = 0
        refreshLevelPing()
    }

    func rescan() {
        TrackMeta.invalidateCaches()
        folderCache.removeAll()
        invalidateSearchScope()
        refreshFavourites()
        if !folderPath.isEmpty,
            !FileManager.default.fileExists(atPath: TrackMeta.url(for: folderPath).path)
        {
            folderPath = ""
        }
        refreshEntries()
        restorePending = SharedDefaults.store.integer(forKey: "restorePending.music")
        Task { [weak self] in
            let scanned = await Task.detached { TrackMeta.scanMusicFolder() }.value
            self?.tracks = scanned
        }
    }

    private func refreshEntries() {
        let path = folderPath
        Task { [weak self] in
            let entries = await Task.detached { TrackMeta.entries(in: path) }.value
            guard let self, self.folderPath == path else { return }
            self.folders = entries.folders
            self.folderTracks = entries.tracks
        }
    }

    func loadSearchScope() {
        let path = folderPath
        guard searchScopePath != path else { return }
        searchScopePath = path
        Task { [weak self] in
            let found = await Task.detached {
                (TrackMeta.tracks(under: path), TrackMeta.folders(under: path))
            }.value
            guard let self, self.searchScopePath == path else { return }
            self.searchTracks = found.0
            self.searchFolders = found.1
        }
    }

    private func invalidateSearchScope() {
        searchScopePath = nil
        searchTracks = []
        searchFolders = []
    }

    func subfolders(of path: String) -> [MusicFolder] {
        if let hit = folderCache[path] { return hit }
        let list = TrackMeta.subfolders(in: path)
        folderCache[path] = list
        return list
    }

    func open(_ folder: MusicFolder) { navigate(to: folder.relativePath) }

    func navigate(to path: String) {
        showingFavourites = false
        folderPath = path
        refreshEntries()
    }

    func reveal(_ track: Track) {
        navigate(to: (track.relativePath as NSString).deletingLastPathComponent)
        SharedDefaults.store.set(
            MainDestination.music.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
    }

    func openFavourites() {
        refreshFavourites()
        showingFavourites = true
    }

    private func refreshFavourites() {
        favourites = Favourites.tracks()
        favouritePaths = Set(favourites.map(\.relativePath))
    }

    func toggleFavourite(_ track: Track) {
        Favourites.toggle(track.relativePath)
        refreshFavourites()
    }

    func playFavourites() {
        send("playSource", MusicSourceRequest.favourites.payload)
    }

    func playFolder(_ folder: MusicFolder) { playAll(under: folder.relativePath) }

    func playCurrentFolder() { playAll(under: folderPath) }

    private func playAll(under relativePath: String) {
        send("playSource", MusicSourceRequest.folder(relativePath).payload)
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
        IPC.post(IPC.Name.requestMusicState)
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

    private func send(_ action: String, _ extra: [String: Any] = [:]) {
        var info: [String: Any] = ["action": action]
        info.merge(extra) { a, _ in a }
        IPC.post(IPC.Name.musicCommand, userInfo: info)
    }

    func toggle(_ track: Track) {
        if showingFavourites, currentFile != track.relativePath {
            send(
                "playSource",
                MusicSourceRequest.favourites.payload.merging(
                    ["start": track.relativePath]) { _, new in new })
            return
        }
        send("toggle", ["track": track.relativePath])
    }
    func playPause() {
        if let videoSession {
            videoSession.toggle()
            return
        }
        send("playPause")
    }
    func pausePlayback() { send("pause") }
    func resumePlayback() { send("resume") }
    func next() {
        leaveVideo()
        send("next")
    }
    func previous() {
        leaveVideo()
        send("previous")
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
        send("seek", ["value": clamped])
    }
    func setVolume(_ value: Double) {
        volume = value
        send("volume", ["value": value])
    }
    func toggleLoop() { send("loop", ["value": !looping]) }
    func toggleShuffle() { send("shuffle", ["value": !shuffling]) }

    func delete(_ track: Track) {
        guard (try? MusicLibrary.trash(track)) != nil else { return }
        rescan()
        broadcastFolderChanged()
    }

    func rename(_ track: Track, to name: String) {
        guard let move = try? MusicLibrary.rename(track, to: name) else { return }
        send("renamed", ["from": move.from, "to": move.to])
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
        guard (try? MusicLibrary.createFolder(named: name, under: folderPath)) != nil else {
            return
        }
        refreshEntries()
        broadcastFolderChanged()
    }

    func move(_ track: Track, toFolderPath folderRelativePath: String) {
        if moveTrack(track, toFolderPath: folderRelativePath) { refreshAfterFileChange() }
    }

    func move(relativePaths: [String], toFolderPath folderRelativePath: String) {
        var moved = false
        for path in relativePaths {
            let track = Track(url: TrackMeta.url(for: path), relativePath: path)
            moved = moveTrack(track, toFolderPath: folderRelativePath) || moved
        }
        if moved { refreshAfterFileChange() }
    }

    private func moveTrack(_ track: Track, toFolderPath folderRelativePath: String) -> Bool {
        guard let move = try? MusicLibrary.move(track, toFolder: folderRelativePath) else {
            return false
        }
        send("renamed", ["from": move.from, "to": move.to])
        return true
    }

    func renameFolder(_ folder: MusicFolder, to name: String) {
        guard sanitizedName(name) != folder.name,
            let renamed = try? MusicLibrary.renameFolder(folder, to: name)
        else { return }
        let newPath = renamed.to
        if let playing = currentFile,
            playing == folder.relativePath || playing.hasPrefix(folder.relativePath + "/")
        {
            send(
                "renamed",
                ["from": playing, "to": newPath + playing.dropFirst(folder.relativePath.count)])
        }
        repointFolderPath(from: folder.relativePath, to: newPath)
        rescan()
        broadcastFolderChanged()
    }

    func deleteFolder(_ folder: MusicFolder) {
        guard (try? MusicLibrary.trashFolder(folder)) != nil else { return }
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
        IPC.post(IPC.Name.musicFolderChanged)
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

struct MusicPage: View {
    @State private var remote = MusicRemote.shared
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.Tabs.musicEnabled, store: SharedDefaults.store) private
        var tabMusicEnabled = false
    @AppStorage(AppStorageKeys.Presenter.blurMusic, store: SharedDefaults.store) private
        var presenterBlurMusic =
        true
    @AppStorage(
        Repo.musicFolderStaleKey, store: SharedDefaults.store)
    private var musicFolderStale = false
    @AppStorage(AppStorageKeys.Music.gridView, store: SharedDefaults.store) private var gridView =
        false
    private var presenterState = PresenterState.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var showDownloader = false
    @State private var deleteTarget: Track?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameFolderTarget: MusicFolder?
    @State private var folderRenameText = ""
    @State private var deleteFolderTarget: MusicFolder?

    private var dark: Bool { scheme == .dark }
    private var theme: Color { themeColor(themeName) }
    private var blurMusic: Bool { presenterState.active && presenterBlurMusic }

    private var filteredTracks: [Track] {
        guard !search.isEmpty else {
            return remote.showingFavourites ? remote.favourites : remote.folderTracks
        }
        let source = remote.showingFavourites ? remote.favourites : remote.searchTracks
        return source.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var filteredFolders: [MusicFolder] {
        guard !remote.showingFavourites else { return [] }
        guard !search.isEmpty else { return remote.folders }
        return remote.searchFolders.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var contentKey: [String] {
        filteredFolders.map(\.relativePath) + filteredTracks.map(\.relativePath)
    }

    private func location(of relativePath: String) -> String? {
        guard !search.isEmpty, !remote.showingFavourites else { return nil }
        let parent = (relativePath as NSString).deletingLastPathComponent
        guard parent != remote.folderPath else { return nil }
        let scoped =
            remote.folderPath.isEmpty
            ? parent : String(parent.dropFirst(remote.folderPath.count + 1))
        return scoped.replacingOccurrences(of: "/", with: " / ")
    }

    private var moveTargets: [MoveTarget] {
        var targets: [MoveTarget] = []
        if !remote.folderPath.isEmpty {
            let parent = (remote.folderPath as NSString).deletingLastPathComponent
            let name = parent.isEmpty ? "Home" : (parent as NSString).lastPathComponent
            targets.append(MoveTarget(name: "\(name) (up)", path: parent))
        }
        targets += remote.folders.map { MoveTarget(name: $0.name, path: $0.relativePath) }
        return targets
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            pageHeader
            trackList
        }
        .background(DashSkin.paper(dark).ignoresSafeArea(edges: .vertical))
        .navigationTitle("Music")
        .sheet(isPresented: $showDownloader) {
            DownloadSheet()
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                remote.createFolder(named: newFolderName)
                newFolderName = ""
            }
        } message: {
            Text(
                "Creates a folder inside \(remote.folderPath.isEmpty ? "your music library" : remote.folderPath)."
            )
        }
        .alert("Rename folder", isPresented: renameFolderBinding) {
            TextField("Folder name", text: $folderRenameText)
            Button("Cancel", role: .cancel) { renameFolderTarget = nil }
            Button("Rename") {
                if let folder = renameFolderTarget {
                    remote.renameFolder(folder, to: folderRenameText)
                }
                renameFolderTarget = nil
            }
        }
        .alert(
            "Move folder to Trash?", isPresented: deleteFolderBinding,
            presenting: deleteFolderTarget
        ) { folder in
            Button("Cancel", role: .cancel) { deleteFolderTarget = nil }
            Button("Move to Trash", role: .destructive) {
                remote.deleteFolder(folder)
                deleteFolderTarget = nil
            }
        } message: { folder in
            Text("\"\(folder.name)\" and everything inside it will be moved to the Trash.")
        }
        .alert(
            "Move to Trash?", isPresented: deleteAlertBinding,
            presenting: deleteTarget
        ) { track in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Move to Trash", role: .destructive) {
                remote.delete(track)
                deleteTarget = nil
            }
        } message: { track in
            Text("\"\(track.title)\" will be moved to the Trash.")
        }
        .onChange(of: search) { if !search.isEmpty { remote.loadSearchScope() } }
        .onChange(of: remote.folderPath) { if !search.isEmpty { remote.loadSearchScope() } }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var renameFolderBinding: Binding<Bool> {
        Binding(get: { renameFolderTarget != nil }, set: { if !$0 { renameFolderTarget = nil } })
    }

    private var deleteFolderBinding: Binding<Bool> {
        Binding(get: { deleteFolderTarget != nil }, set: { if !$0 { deleteFolderTarget = nil } })
    }

    private func openDetails(_ track: Track, renaming: Bool) {
        MusicDetailPresenter.shared.show(track, renaming: renaming)
    }

    private var pageHeader: some View {
        PageHeader("Music") {
            headerActions
        } accessory: {
            VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                if musicFolderStale {
                    HStack(spacing: UIScale.pt(5)) {
                        Text("A previous external music folder was skipped.")
                        Button("Choose it again", action: chooseMusicFolder)
                            .buttonStyle(.link)
                    }
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
                }
                searchField
                breadcrumbBar
                if tabMusicEnabled, remote.restorePending > 0 {
                    Text("Restoring your music from iCloud, \(remote.restorePending) remaining")
                        .settingsCaption()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: UIScale.pt(4)) {
            Button {
                gridView.toggle()
            } label: {
                Image(systemName: gridView ? "list.bullet" : "square.grid.2x2")
            }
            .buttonStyle(HoverButtonStyle())
            .help(gridView ? "Show as list" : "Show as grid")
            Button {
                if remote.showingFavourites {
                    remote.navigate(to: remote.folderPath)
                } else {
                    remote.openFavourites()
                }
            } label: {
                Image(systemName: remote.showingFavourites ? "heart.fill" : "heart")
                    .foregroundStyle(
                        remote.showingFavourites
                            ? AnyShapeStyle(theme) : AnyShapeStyle(.primary))
            }
            .buttonStyle(HoverButtonStyle())
            .help(remote.showingFavourites ? "Back to your folders" : "Show favourites")
            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(HoverButtonStyle())
            .help("New folder")
            Button {
                try? FileManager.default.createDirectory(
                    at: Repo.musicDir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Repo.musicDir)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Open music folder in Finder")
            Button {
                remote.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Rescan music folder")
            Button {
                showDownloader = true
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(HoverButtonStyle())
            .help("Download YouTube audio")
        }
    }

    private var searchField: some View {
        SearchField(placeholder: "Search tracks", text: $search, typeAhead: true)
    }

    private var crumbSegments: [(name: String, path: String)] {
        guard !remote.folderPath.isEmpty else { return [] }
        var cumulative = ""
        return remote.folderPath.split(separator: "/").map { part in
            cumulative = cumulative.isEmpty ? String(part) : cumulative + "/" + part
            return (String(part), cumulative)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: UIScale.pt(8)) {
            if remote.showingFavourites {
                Label("Favourites", systemImage: "heart.fill")
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .foregroundStyle(theme)
                    .padding(.vertical, UIScale.pt(6))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: UIScale.pt(4)) {
                        crumb("Home", path: "", systemImage: "house.fill")
                        chevronMenu(parentPath: "")
                        ForEach(crumbSegments, id: \.path) { segment in
                            crumb(segment.name, path: segment.path, systemImage: nil)
                            chevronMenu(parentPath: segment.path)
                        }
                    }
                    .padding(.vertical, UIScale.pt(2))
                    .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.hidden)
            }
            Spacer(minLength: UIScale.pt(8))
            Button {
                if remote.showingFavourites {
                    remote.playFavourites()
                } else {
                    remote.playCurrentFolder()
                }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, UIScale.pt(14))
                    .padding(.vertical, UIScale.pt(7))
                    .liquidGlass(in: Capsule(), tint: theme, interactive: true, dark: dark)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(
                remote.showingFavourites
                    ? "Play your favourites" : "Play everything in this folder")
        }
    }

    private func crumb(_ name: String, path: String, systemImage: String?) -> some View {
        CrumbButton(
            name: name, path: path, systemImage: systemImage, theme: theme,
            isCurrent: path == remote.folderPath,
            onTap: { remote.navigate(to: path) },
            onDrop: { remote.move(relativePaths: $0, toFolderPath: path) }
        )
    }

    @ViewBuilder
    private func chevronMenu(parentPath: String) -> some View {
        let folders = remote.subfolders(of: parentPath)
        if folders.isEmpty {
            Image(systemName: "chevron.right")
                .font(.system(size: UIScale.pt(9)))
                .foregroundStyle(.tertiary)
        } else {
            Menu {
                ForEach(folders) { folder in
                    Button(folder.name) { remote.navigate(to: folder.relativePath) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: UIScale.pt(9), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(16), height: UIScale.pt(16))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .help("Jump to a folder here")
        }
    }

    @ViewBuilder private var trackList: some View {
        if filteredFolders.isEmpty && filteredTracks.isEmpty {
            VStack(spacing: UIScale.pt(8)) {
                Text(emptyMessage)
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(.secondary)
                Text(
                    remote.showingFavourites
                        ? "Tap the heart on a track to add it here"
                        : TrackMeta.url(for: remote.folderPath).path
                )
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Group {
                    if gridView { gridContent } else { listContent }
                }
                .pageContent(compact)
                .animation(
                    Motion.animation(Motion.glide, reduceMotion: reduceMotion), value: contentKey)
            }
        }
    }

    private var listContent: some View {
        LazyVStack(spacing: UIScale.pt(2)) {
            ForEach(filteredFolders) { folder in
                MusicFolderRow(
                    folder: folder, theme: theme, location: location(of: folder.relativePath),
                    onOpen: { remote.open(folder) },
                    onPlay: { remote.playFolder(folder) },
                    onDrop: {
                        remote.move(relativePaths: $0, toFolderPath: folder.relativePath)
                    },
                    onRename: { beginFolderRename(folder) },
                    onDelete: { deleteFolderTarget = folder }
                )
            }
            ForEach(filteredTracks) { track in
                MusicPageRow(
                    track: track, location: location(of: track.relativePath),
                    isCurrent: remote.currentFile == track.relativePath,
                    isPlaying: remote.isPlaying, theme: theme, blur: blurMusic,
                    moveTargets: moveTargets,
                    isFavourite: remote.favouritePaths.contains(track.relativePath),
                    onOpenDetails: { openDetails(track, renaming: false) },
                    onRename: { openDetails(track, renaming: true) },
                    onDelete: { deleteTarget = track },
                    onMove: { remote.move(track, toFolderPath: $0) },
                    onToggle: { remote.toggle(track) },
                    onToggleFavourite: { remote.toggleFavourite(track) },
                    onOpenFolder: { remote.reveal(track) }
                )
            }
        }
    }

    private var gridContent: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: MusicTile.width, maximum: MusicTile.width),
                    spacing: UIScale.pt(14))
            ],
            alignment: .leading, spacing: UIScale.pt(16)
        ) {
            ForEach(filteredFolders) { folder in
                MusicFolderTile(
                    folder: folder, theme: theme, location: location(of: folder.relativePath),
                    onOpen: { remote.open(folder) },
                    onPlay: { remote.playFolder(folder) },
                    onDrop: {
                        remote.move(relativePaths: $0, toFolderPath: folder.relativePath)
                    },
                    onRename: { beginFolderRename(folder) },
                    onDelete: { deleteFolderTarget = folder }
                )
            }
            ForEach(filteredTracks) { track in
                MusicTrackTile(
                    track: track, location: location(of: track.relativePath),
                    isCurrent: remote.currentFile == track.relativePath,
                    isPlaying: remote.isPlaying, theme: theme, blur: blurMusic,
                    moveTargets: moveTargets,
                    isFavourite: remote.favouritePaths.contains(track.relativePath),
                    onOpenDetails: { openDetails(track, renaming: false) },
                    onRename: { openDetails(track, renaming: true) },
                    onDelete: { deleteTarget = track },
                    onMove: { remote.move(track, toFolderPath: $0) },
                    onToggle: { remote.toggle(track) },
                    onToggleFavourite: { remote.toggleFavourite(track) },
                    onOpenFolder: { remote.reveal(track) }
                )
            }
        }
    }

    private var emptyMessage: String {
        if remote.showingFavourites { return "No favourites yet" }
        return remote.folderPath.isEmpty
            ? "No playable files in your music folder" : "This folder is empty"
    }

    private func beginFolderRename(_ folder: MusicFolder) {
        folderRenameText = folder.name
        renameFolderTarget = folder
    }

    private func chooseMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your music folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Repo.setMusicDirectory(url)
        remote.rescan()
        IPC.post(IPC.Name.musicFolderChanged)
    }

}

struct SeekBar: View {
    @State private var remote = MusicRemote.shared
    @ObservedObject private var visibility = WindowVisibility.shared
    let theme: Color
    var height: CGFloat = 5
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let knob = max(11, height + 7)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                if remote.isPlaying, visibility.visible, dragFraction == nil {
                    TimelineView(.periodic(from: MusicTick.epoch, by: 0.5)) { _ in
                        fill(geo.size.width, knob)
                    }
                } else {
                    fill(geo.size.width, knob)
                }
            }
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded { value in
                        remote.seek(to: min(max(value.location.x / geo.size.width, 0), 1))
                        dragFraction = nil
                    }
            )
        }
        .frame(height: height)
        .pointerCursor()
    }

    private func fill(_ width: CGFloat, _ knob: CGFloat) -> some View {
        let fraction = dragFraction ?? remote.progress
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(theme.opacity(0.85))
                .frame(width: width)
                .mask(alignment: .leading) {
                    Rectangle()
                        .scaleEffect(
                            x: width > 0 ? max(height, width * fraction) / width : 0,
                            anchor: .leading)
                }
            Circle()
                .fill(theme)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.25), radius: UIScale.pt(2), y: 1)
                .offset(x: min(max(width * fraction - knob / 2, 0), width - knob))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CrumbButton: View {
    let name: String
    let path: String
    let systemImage: String?
    let theme: Color
    let isCurrent: Bool
    let onTap: () -> Void
    let onDrop: ([String]) -> Void
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: UIScale.pt(3)) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: UIScale.pt(10)))
            }
            Text(name).lineLimit(1)
        }
        .font(.system(size: UIScale.pt(12), weight: isCurrent ? .semibold : .regular))
        .foregroundStyle(isCurrent ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
        .padding(.horizontal, UIScale.pt(7))
        .padding(.vertical, UIScale.pt(4))
        .background(
            dropTargeted ? theme.opacity(0.2) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(6))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .pointerCursor()
        .dropDestination(for: String.self) { paths, _ in
            guard !isCurrent else { return false }
            onDrop(paths)
            return !paths.isEmpty
        } isTargeted: {
            dropTargeted = $0 && !isCurrent
        }
    }
}

private struct MusicFolderRow: View {
    let folder: MusicFolder
    let theme: Color
    let location: String?
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDrop: ([String]) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var trackCount: Int?

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(action: onOpen) {
                HStack(spacing: UIScale.pt(10)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UIScale.pt(7))
                            .fill(theme.opacity(0.16))
                            .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                        Image(systemName: "folder.fill")
                            .font(.system(size: UIScale.pt(14)))
                            .foregroundStyle(theme)
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text(folder.name)
                            .font(.system(size: UIScale.pt(13), weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(
                            location ?? trackCount.map { "\($0) track\($0 == 1 ? "" : "s")" } ?? " "
                        )
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: UIScale.pt(22)))
                    .foregroundStyle(theme)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Play this folder")
            .opacity(hovering || trackCount == 0 ? 1 : 0.55)

            Image(systemName: "chevron.right")
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, UIScale.pt(6))
        .padding(.horizontal, UIScale.pt(8))
        .background(
            dropTargeted
                ? theme.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .strokeBorder(theme, lineWidth: dropTargeted ? UIScale.pt(1.5) : 0)
        )
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { paths, _ in
            onDrop(paths)
            return !paths.isEmpty
        } isTargeted: {
            dropTargeted = $0
        }
        .contextMenu {
            folderMenu(
                folder, onOpen: onOpen, onPlay: onPlay, onRename: onRename, onDelete: onDelete)
        }
        .task(id: folder.relativePath) {
            let path = folder.relativePath
            trackCount = TrackMeta.cachedTrackCount(under: path)
            trackCount = await Task.detached { TrackMeta.trackCount(under: path) }.value
        }
    }
}

struct MoveTarget: Identifiable, Equatable {
    let name: String
    let path: String
    var id: String { path }
}

private struct MusicPageRow: View {
    let track: Track
    let location: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let blur: Bool
    let moveTargets: [MoveTarget]
    let isFavourite: Bool
    let onOpenDetails: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void
    let onToggle: () -> Void
    let onToggleFavourite: () -> Void
    let onOpenFolder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var duration: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Button(action: onOpenDetails) {
                PageArtworkThumb(track: track, size: 34)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Show details")
            Button(action: onToggle) {
                HStack(spacing: UIScale.pt(10)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(1)) {
                        Text(track.title)
                            .font(.system(size: UIScale.pt(13)))
                            .lineLimit(1)
                            .foregroundStyle(isCurrent ? theme : .primary)
                            .presenterBlur(blur)
                        if let location {
                            Text(location)
                                .font(.system(size: UIScale.pt(10.5)))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                    if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(theme)
                    }
                    Text(duration ?? "")
                        .font(.system(size: UIScale.pt(11)))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: onToggleFavourite) {
                Image(systemName: isFavourite ? "heart.fill" : "heart")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(isFavourite ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isFavourite ? "Remove from favourites" : "Add to favourites")
            .opacity(hovering || isFavourite ? 1 : 0)
        }
        .padding(.vertical, UIScale.pt(6))
        .padding(.horizontal, UIScale.pt(8))
        .background(
            isCurrent
                ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(7))
        )
        .onHover { hovering = $0 }
        .draggable(track.relativePath)
        .contextMenu {
            trackMenu(
                track, moveTargets: moveTargets, isFavourite: isFavourite,
                onOpenDetails: onOpenDetails, onRename: onRename, onDelete: onDelete,
                onMove: onMove, onToggleFavourite: onToggleFavourite,
                onOpenFolder: onOpenFolder)
        }
        .task {
            duration = TrackMeta.cachedDurationLabel(for: track)
            duration = await TrackMeta.durationLabel(for: track)
        }
    }
}

@ViewBuilder
private func folderMenu(
    _ folder: MusicFolder, onOpen: @escaping () -> Void, onPlay: @escaping () -> Void,
    onRename: @escaping () -> Void, onDelete: @escaping () -> Void
) -> some View {
    Button("Play", action: onPlay)
    Button("Open", action: onOpen)
    Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }
    Button("Rename", action: onRename)
    Button("Move to Trash", role: .destructive, action: onDelete)
}

@ViewBuilder
private func trackMenu(
    _ track: Track, moveTargets: [MoveTarget], isFavourite: Bool,
    onOpenDetails: @escaping () -> Void, onRename: @escaping () -> Void,
    onDelete: @escaping () -> Void, onMove: @escaping (String) -> Void,
    onToggleFavourite: @escaping () -> Void, onOpenFolder: @escaping () -> Void
) -> some View {
    Button(
        isFavourite ? "Remove from Favourites" : "Add to Favourites", action: onToggleFavourite)
    Button("Show Details", action: onOpenDetails)
    Button("Open Enclosing Folder", action: onOpenFolder)
    Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([track.url])
    }
    Button("Rename", action: onRename)
    if !moveTargets.isEmpty {
        Menu("Move to Folder") {
            ForEach(moveTargets) { target in
                Button(target.name) { onMove(target.path) }
            }
        }
    }
    Button("Move to Trash", role: .destructive, action: onDelete)
}

private enum MusicTile {
    static let art = 118.0
    static let inset = 6.0
    static var artSize: CGFloat { UIScale.pt(art) }
    static var width: CGFloat { UIScale.pt(art + inset * 2) }
}

private struct MusicFolderTile: View {
    let folder: MusicFolder
    let theme: Color
    let location: String?
    let onOpen: () -> Void
    let onPlay: () -> Void
    let onDrop: ([String]) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var trackCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(12))
                    .fill(theme.opacity(0.16))
                Image(systemName: "folder.fill")
                    .font(.system(size: UIScale.pt(34)))
                    .foregroundStyle(theme)
            }
            .frame(width: MusicTile.artSize, height: MusicTile.artSize)
            .overlay(alignment: .bottomTrailing) {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: UIScale.pt(24)))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, theme)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Play this folder")
                .opacity(hovering ? 1 : 0)
                .padding(UIScale.pt(7))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .pointerCursor()

            VStack(spacing: UIScale.pt(1)) {
                Text(folder.name)
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .lineLimit(1)
                Text(location ?? trackCount.map { "\($0) track\($0 == 1 ? "" : "s")" } ?? " ")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(width: MusicTile.artSize)
        }
        .padding(UIScale.pt(6))
        .background(
            dropTargeted
                ? theme.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIScale.pt(10))
                .strokeBorder(theme, lineWidth: dropTargeted ? UIScale.pt(1.5) : 0)
        )
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { paths, _ in
            onDrop(paths)
            return !paths.isEmpty
        } isTargeted: {
            dropTargeted = $0
        }
        .contextMenu {
            folderMenu(
                folder, onOpen: onOpen, onPlay: onPlay, onRename: onRename, onDelete: onDelete)
        }
        .task(id: folder.relativePath) {
            let path = folder.relativePath
            trackCount = TrackMeta.cachedTrackCount(under: path)
            trackCount = await Task.detached { TrackMeta.trackCount(under: path) }.value
        }
    }
}

private struct MusicTrackTile: View {
    let track: Track
    let location: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let theme: Color
    let blur: Bool
    let moveTargets: [MoveTarget]
    let isFavourite: Bool
    let onOpenDetails: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMove: (String) -> Void
    let onToggle: () -> Void
    let onToggleFavourite: () -> Void
    let onOpenFolder: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var duration: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            PageArtworkThumb(track: track, size: MusicTile.artSize)
                .overlay(alignment: .bottomTrailing) {
                    Image(
                        systemName: isCurrent && isPlaying
                            ? "pause.circle.fill" : "play.circle.fill"
                    )
                    .font(.system(size: UIScale.pt(24)))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, theme)
                    .opacity(hovering || isCurrent ? 1 : 0)
                    .padding(UIScale.pt(7))
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onToggleFavourite) {
                        Image(systemName: isFavourite ? "heart.fill" : "heart")
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(isFavourite ? theme : .white)
                            .shadow(color: .black.opacity(0.5), radius: UIScale.pt(2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isFavourite ? "Remove from favourites" : "Add to favourites")
                    .opacity(hovering || isFavourite ? 1 : 0)
                    .padding(UIScale.pt(7))
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .pointerCursor()

            VStack(spacing: UIScale.pt(1)) {
                Text(track.title)
                    .font(.system(size: UIScale.pt(12)))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isCurrent ? theme : .primary)
                    .presenterBlur(blur)
                Text(location ?? duration ?? " ")
                    .font(.system(size: UIScale.pt(10.5)))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .frame(width: MusicTile.artSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpenDetails)
            .pointerCursor()
            .help("Show details")
        }
        .padding(UIScale.pt(6))
        .background(
            isCurrent
                ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.05) : .clear,
            in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .onHover { hovering = $0 }
        .draggable(track.relativePath)
        .contextMenu {
            trackMenu(
                track, moveTargets: moveTargets, isFavourite: isFavourite,
                onOpenDetails: onOpenDetails, onRename: onRename, onDelete: onDelete,
                onMove: onMove, onToggleFavourite: onToggleFavourite,
                onOpenFolder: onOpenFolder)
        }
        .task {
            duration = TrackMeta.cachedDurationLabel(for: track)
            duration = await TrackMeta.durationLabel(for: track)
        }
    }
}

struct MusicDetailOverlay: View {
    @State private var presenter = MusicDetailPresenter.shared
    @State private var remote = MusicRemote.shared
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleteTarget: Track?

    private var theme: Color { themeColor(themeName) }

    private var sheetShape: String? {
        presenter.track.map { $0.isVideo ? "video" : "audio" }
    }

    var body: some View {
        ZStack {
            if let track = presenter.track {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { presenter.dismiss() }
                    .transition(.opacity)
                MusicDetailSheet(
                    track: track,
                    theme: theme,
                    beginRename: presenter.beginRename,
                    onRename: { remote.rename(track, to: $0) },
                    onDelete: {
                        presenter.dismiss()
                        deleteTarget = track
                    },
                    onOpenFolder: {
                        remote.navigate(to: $0)
                        mainWindowSection = MainDestination.music.rawValue
                    },
                    onClose: { presenter.dismiss() }
                )
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(16)))
                .shadow(color: .black.opacity(0.45), radius: UIScale.pt(40), y: UIScale.pt(16))
                .padding(UIScale.pt(24))
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                Button("Close", action: presenter.dismiss)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: sheetShape)
        .animation(
            Motion.animation(.smooth(duration: 0.32), reduceMotion: reduceMotion),
            value: presenter.renameArmed
        )
        .onChange(of: remote.currentFile) { presenter.followCurrent() }
        .alert(
            "Move to Trash?",
            isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { track in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Move to Trash", role: .destructive) {
                remote.delete(track)
                deleteTarget = nil
            }
        } message: { track in
            Text("\"\(track.title)\" will be moved to the Trash.")
        }
    }
}

private struct MusicDetailSheet: View {
    let track: Track
    let theme: Color
    let beginRename: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onOpenFolder: (String) -> Void
    let onClose: () -> Void
    @State private var remote = MusicRemote.shared
    @State private var presenter = MusicDetailPresenter.shared
    @Environment(\.colorScheme) private var scheme
    @State private var name = ""
    @State private var namedTrack: URL?
    @FocusState private var nameFocused: Bool
    @State private var sourceURL: URL?

    private var dark: Bool { scheme == .dark }
    private var isCurrent: Bool { remote.currentFile == track.relativePath }
    private var isPlaying: Bool { isCurrent && remote.isPlaying }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            header
            content
        }
        .frame(width: UIScale.pt(track.isVideo ? 760 : 400))
        .background(sheetBackground)
        .task(id: track.id) {
            name = track.url.deletingPathExtension().lastPathComponent
            namedTrack = track.id
            sourceURL = YoutubeDownloader.shared.sourceURL(
                forFileNamed: track.url.lastPathComponent)
            if beginRename { nameFocused = true }
            presenter.armRename(false)
        }
    }

    private var sheetBackground: some View {
        LinearGradient(
            colors: [
                Color(
                    hue: track.hue, saturation: dark ? 0.28 : 0.14, brightness: dark ? 0.2 : 0.99),
                DashSkin.paper(dark),
            ],
            startPoint: .top, endPoint: .center
        )
        .overlay(DashSkin.paper(dark).opacity(dark ? 0.35 : 0.15))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(8)) {
            Spacer()
            headerButton("trash", tint: .red, help: "Move to Trash", action: onDelete)
            headerButton("xmark", tint: .secondary, help: "Close", action: onClose)
        }
        .padding(.horizontal, UIScale.pt(16))
        .padding(.top, UIScale.pt(14))
    }

    private func headerButton(
        _ symbol: String, tint: some ShapeStyle, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                .background(DashSkin.paper2(dark).opacity(0.6), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }

    private var content: some View {
        VStack(spacing: UIScale.pt(0)) {
            VStack(spacing: UIScale.pt(20)) {
                stage
                    .padding(.top, UIScale.pt(2))
                titleField
                folderPath
                if isCurrent, !track.isVideo {
                    playerBlock
                }
                if let sourceURL {
                    youtubeLink(sourceURL)
                }
            }
            renameReveal
        }
        .padding(.horizontal, UIScale.pt(28))
        .padding(.bottom, UIScale.pt(28))
        .padding(.top, UIScale.pt(6))
    }

    @ViewBuilder private var stage: some View {
        if track.isVideo {
            VideoStage(track: track, startAt: isCurrent ? remote.elapsed : 0)
                .id(track.id)
                .transition(.opacity)
        } else {
            artwork
                .transition(.opacity)
        }
    }

    private var folderPath: some View {
        let parent = (track.relativePath as NSString).deletingLastPathComponent
        return Button {
            onOpenFolder(parent)
            onClose()
        } label: {
            HStack(spacing: UIScale.pt(5)) {
                Image(systemName: "folder")
                Text(parent.isEmpty ? "Music" : parent.replacingOccurrences(of: "/", with: " / "))
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "arrow.right")
                    .font(.system(size: UIScale.pt(8), weight: .semibold))
            }
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .foregroundStyle(theme)
            .padding(.horizontal, UIScale.pt(10))
            .padding(.vertical, UIScale.pt(6))
            .background(theme.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Show this folder in Music")
    }

    private var artwork: some View {
        PageArtworkThumb(track: track, size: 196)
            .shadow(color: .black.opacity(0.3), radius: UIScale.pt(16), y: UIScale.pt(8))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    remote.toggle(track)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: UIScale.pt(19), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: UIScale.pt(52), height: UIScale.pt(52))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .liquidGlass(in: Circle(), tint: theme, interactive: true, dark: dark)
                .shadow(color: .black.opacity(0.28), radius: UIScale.pt(8), y: UIScale.pt(3))
                .pointerCursor()
                .help(isPlaying ? "Pause" : "Play")
                .offset(x: UIScale.pt(10), y: UIScale.pt(10))
            }
    }

    private var titleField: some View {
        TextField("Track name", text: nameBinding)
            .textFieldStyle(.plain)
            .font(.system(size: UIScale.pt(17), weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(DashSkin.ink(dark))
            .focused($nameFocused)
            .padding(.horizontal, UIScale.pt(14))
            .padding(.vertical, UIScale.pt(10))
            .background(
                DashSkin.paper2(dark).opacity(nameFocused ? 1 : 0),
                in: RoundedRectangle(cornerRadius: UIScale.pt(10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(
                        nameFocused ? theme : .clear, lineWidth: UIScale.pt(1))
            )
            .onSubmit(commitRename)
    }

    private var playerBlock: some View {
        VStack(spacing: UIScale.pt(8)) {
            SeekBar(theme: theme, height: UIScale.pt(5))
            HStack {
                ticker { Text(TrackMeta.timeLabel(remote.elapsed)) }
                Spacer()
                Label(isPlaying ? "Now Playing" : "Paused", systemImage: "waveform")
                    .font(.system(size: UIScale.pt(10.5), weight: .medium))
                    .foregroundStyle(theme)
                Spacer()
                ticker {
                    Text("-" + TrackMeta.timeLabel(max(remote.duration - remote.elapsed, 0)))
                }
            }
            .font(.system(size: UIScale.pt(10.5)))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func ticker<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View
    {
        if isPlaying {
            TimelineView(.periodic(from: MusicTick.epoch, by: 1)) { _ in content() }
        } else {
            content()
        }
    }

    private func youtubeLink(_ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: "play.rectangle.fill")
                Text("Open original on YouTube")
                    .lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: UIScale.pt(9)))
            }
            .font(.system(size: UIScale.pt(11.5), weight: .medium))
            .foregroundStyle(theme)
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(8))
            .background(theme.opacity(0.1), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var renameReveal: some View {
        Button(action: commitRename) {
            Label("Rename", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
                .frame(height: UIScale.pt(Self.renameButtonHeight))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .background(theme, in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
        .pointerCursor()
        .font(.system(size: UIScale.pt(12.5), weight: .semibold))
        .padding(.top, UIScale.pt(Self.renameButtonGap))
        .frame(height: canRename ? UIScale.pt(Self.renameRowHeight) : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(canRename)
    }

    private static let renameButtonHeight = 40.0
    private static let renameButtonGap = 20.0
    private static var renameRowHeight: Double { renameButtonHeight + renameButtonGap }

    private var nameBinding: Binding<String> {
        Binding(
            get: { name },
            set: { value in
                name = value
                presenter.armRename(isRenameable(value))
            })
    }

    private var canRename: Bool { presenter.renameArmed && namedTrack == track.id }

    private func isRenameable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != track.url.deletingPathExtension().lastPathComponent
    }

    private func commitRename() {
        if isRenameable(name) { onRename(name) }
        onClose()
    }
}

@available(macOS 26, *)
private enum GlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(
        in shape: S, tint: Color? = nil, interactive: Bool = false, dark: Bool = false
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(GlassStyle.make(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background((tint ?? .clear).opacity(tint == nil ? 0 : 0.28), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(dark ? 0.16 : 0.4), lineWidth: 1))
        }
    }
}

struct MusicFooter: View {
    @State private var remote = MusicRemote.shared
    @ObservedObject private var visibility = WindowVisibility.shared
    @AppStorage(AppStorageKeys.General.mainWindowSection, store: SharedDefaults.store) private
        var mainWindowSection =
        MainDestination.home.rawValue
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
    @AppStorage(AppStorageKeys.Presenter.blurMusic, store: SharedDefaults.store) private
        var presenterBlurMusic =
        true
    private var presenterState = PresenterState.shared
    @Environment(\.colorScheme) private var scheme

    private var theme: Color { themeColor(themeName) }
    private var blur: Bool { presenterState.active && presenterBlurMusic }
    private var dark: Bool { scheme == .dark }

    var body: some View {
        Group {
            if let track = remote.current {
                playing(track)
            } else {
                idle
            }
        }
        .frame(height: UIScale.pt(64))
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: UIScale.pt(1))
        }
    }

    private func playing(_ track: Track) -> some View {
        HStack(spacing: UIScale.pt(14)) {
            trackInfo(track)
                .frame(maxWidth: .infinity, alignment: .leading)
            transport
            scrubber
                .frame(maxWidth: UIScale.pt(420))
            rightControls
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, UIScale.pt(22))
    }

    private func trackInfo(_ track: Track) -> some View {
        HStack(spacing: UIScale.pt(11)) {
            Button {
                MusicDetailPresenter.shared.show(track)
            } label: {
                PageArtworkThumb(track: track, size: 44)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(track.isVideo ? "Watch this video" : "Show details")
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(track.title)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .lineLimit(1)
                    .presenterBlur(blur)
                Text(remote.isPlaying ? "Now playing" : "Paused")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.secondary)
                    .frame(width: UIScale.pt(78), alignment: .leading)
            }
            PlaybackWave(
                playing: remote.isPlaying && visibility.visible, color: theme.opacity(0.9),
                maxHeight: UIScale.pt(13))
        }
        .contentShape(Rectangle())
        .onTapGesture { remote.reveal(track) }
        .pointerCursor()
        .help("Show this track in Music")
    }

    private var transport: some View {
        HStack(spacing: UIScale.pt(8)) {
            glassButton("backward.fill", diameter: 34, iconSize: 12, tint: nil) {
                remote.previous()
            }
            .help("Previous track")
            glassButton(
                remote.isPlaying ? "pause.fill" : "play.fill",
                diameter: 42, iconSize: 15, iconColor: .white, tint: theme
            ) {
                remote.playPause()
            }
            .help("Play or pause")
            glassButton("forward.fill", diameter: 34, iconSize: 12, tint: nil) {
                remote.next()
            }
            .help("Next track")
        }
    }

    private func glassButton(
        _ symbol: String, diameter: CGFloat, iconSize: CGFloat, iconColor: Color? = nil,
        tint: Color?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(iconSize), weight: .semibold))
                .foregroundStyle(iconColor ?? theme)
                .frame(width: UIScale.pt(diameter), height: UIScale.pt(diameter))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .liquidGlass(in: Circle(), tint: tint, interactive: true, dark: dark)
    }

    private var scrubber: some View {
        HStack(spacing: UIScale.pt(10)) {
            timeTicker {
                Text(TrackMeta.timeLabel(remote.elapsed))
                    .frame(width: UIScale.pt(42), alignment: .trailing)
            }
            SeekBar(theme: theme, height: UIScale.pt(4))
            timeTicker {
                Text("-" + TrackMeta.timeLabel(max(remote.duration - remote.elapsed, 0)))
                    .frame(width: UIScale.pt(46), alignment: .leading)
            }
        }
        .font(.system(size: UIScale.pt(10.5)))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func timeTicker<Content: View>(@ViewBuilder _ content: @escaping () -> Content)
        -> some View
    {
        if remote.isPlaying, visibility.visible {
            TimelineView(.periodic(from: MusicTick.epoch, by: 1)) { _ in content() }
        } else {
            content()
        }
    }

    private var rightControls: some View {
        HStack(spacing: UIScale.pt(10)) {
            if let track = remote.current {
                let liked = remote.favouritePaths.contains(track.relativePath)
                glassButton(
                    liked ? "heart.fill" : "heart", diameter: 34, iconSize: 12,
                    iconColor: liked ? .white : .secondary,
                    tint: liked ? theme : nil
                ) {
                    remote.toggleFavourite(track)
                }
                .help(liked ? "Remove from favourites" : "Add to favourites")
            }
            glassButton(
                "shuffle", diameter: 34, iconSize: 12,
                iconColor: remote.shuffling ? .white : .secondary,
                tint: remote.shuffling ? theme : nil
            ) {
                remote.toggleShuffle()
            }
            .help(remote.shuffling ? "Shuffling this folder and everything in it" : "Play in order")
            glassButton(
                "repeat", diameter: 34, iconSize: 12,
                iconColor: remote.looping ? .white : .secondary,
                tint: remote.looping ? theme : nil
            ) {
                remote.toggleLoop()
            }
            .help(remote.looping ? "Repeating this track" : "Play through the queue")
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: "speaker.wave.1")
                    .settingsCaption()
                Slider(
                    value: Binding(get: { remote.volume }, set: { remote.setVolume($0) }),
                    in: 0...1
                )
                .controlSize(.mini)
                .tint(theme)
                .frame(width: UIScale.pt(80))
                .pointerCursor()
            }
            .padding(.horizontal, UIScale.pt(12))
            .padding(.vertical, UIScale.pt(7))
            .liquidGlass(in: Capsule(), dark: dark)
        }
    }

    private var idle: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: "music.note")
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                mainWindowSection = MainDestination.music.rawValue
            } label: {
                Text("Browse music")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
        }
        .padding(.horizontal, UIScale.pt(22))
    }
}

private struct PageArtworkThumb: View {
    let track: Track
    let size: CGFloat
    @State private var artwork: NSImage?

    init(track: Track, size: CGFloat = 36) {
        self.track = track
        self.size = size
        _artwork = State(initialValue: TrackMeta.artworkCached(for: track))
    }

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
        .task(id: track.id) {
            if track.isVideo, TrackMeta.artworkCached(for: track) == nil {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            artwork = await TrackMeta.artwork(for: track)
        }
    }
}
