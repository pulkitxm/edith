import AppKit
import EdithExtensionSupport
import Foundation
import EdithExtensionUI
import WebKit

@MainActor final class MusicUIService {
    private let worker: MusicWorker
    private let version: String
    private let browser: MusicBrowserPresentation
    private var downloads: MusicDownloadsService?
    private var libraryPanel: NSOpenPanel?

    private var events: [MusicUIEvent] = []
    private var sequence = 0
    private var video: MusicVideoPlayback?
    private var videoDeadline: Task<Void, Never>?
    private var videoActivity = Date()
    private var resumeAudio = false
    private var stopped = false
    init(worker: MusicWorker, version: String = "", browser: MusicBrowserPresentation? = nil) {
        self.worker = worker
        self.version = version
        self.browser =
            browser
            ?? MusicBrowserPresentation(
                connected: {
                    worker.accounts.youtubeConnected && worker.accounts.selected == .youtubeMusic
                },
                cookies: { await worker.accounts.presentationCookies() })
        worker.browserPresentation = self.browser
        worker.player.presentationTransport = { [weak self] request in
            guard let self, self.video != nil else { return false }
            switch request {
            case .shuffle, .repeat, .status: return false;
            default: self.transport(request); return true
            }
        }
        worker.player.presentationSnapshot = { [weak self] in
            guard let self, let video = self.video else { return nil }
            var snapshot = self.playbackSnapshot(); snapshot.title = video.track.title
            return snapshot
        }
        MusicHostNavigation.reset()
        worker.accounts.spotify.receiveUIEvent = { [weak self] event in
            guard let self, let data = try? JSONSerialization.data(withJSONObject: event),
                data.count <= 262_144
            else { return }
            self.sequence += 1
            self.events.append(.init(sequence: self.sequence, data: data))
            if self.events.count > 64 { self.events.removeFirst() }
        }
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if operation.hasPrefix("music.ui.downloads.") {
            if downloads == nil { downloads = MusicDownloadsService(worker: worker) }
            return try await downloads!.execute(operation, payload: payload)
        }
        switch operation {
        case "music.ui.hostSlots":
            guard payload.count <= 256,
                let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                request.isEmpty, !version.isEmpty, version.utf8.count <= 128,
                !version.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
            let accounts = worker.accounts
            let title: String?
            switch accounts.selected {
            case .local: title = worker.player.current?.title
            case .spotify: title = accounts.spotify.title.isEmpty ? nil : accounts.spotify.title
            case .youtubeMusic: title = accounts.youtubeConnected ? "YouTube Music" : nil
            }
            let defaults = SharedDefaults.store
            let visible =
                accounts.playerReady
                && (!defaults.bool(forKey: AppStorageKeys.Music.barAutoHide) || title != nil)
            let collapsed = defaults.bool(forKey: AppStorageKeys.Music.barCollapsed)
            return try JSONEncoder().encode(
                MusicHostSlots(
                    version: version, footer: visible && !collapsed, sidebar: visible && collapsed))
        case "music.ui.level":
            return try JSONEncoder().encode(worker.player.readLevel())
        case "music.ui.read":
            let query = try JSONDecoder().decode(MusicUIQuery.self, from: payload)
            try MusicUIAction(kind: .startFolder, path: query.path, target: query.search).validate()
            let path = query.path
            let search = query.search
            let library = await Task.detached {
                let entries = TrackMeta.entries(in: path)
                let results = TrackMeta.searchPage(under: path, query: search, skip: 0, limit: nil)
                return (TrackMeta.scanMusicFolder(), entries, results, Favourites.tracks())
            }.value
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            let player = worker.player
            let accounts = worker.accounts
            let spotify = accounts.spotify
            func entry(_ track: Track) -> MusicUIEntry {
                .init(path: track.relativePath, url: track.url)
            }
            func folder(_ folder: MusicFolder) -> MusicUIEntry {
                .init(path: folder.relativePath, url: folder.url)
            }
            let state = MusicUIState(
                root: MusicStorage.musicDir, tracks: library.0.map(entry),
                folders: library.1.folders.map(folder), folderTracks: library.1.tracks.map(entry),
                searchTracks: library.2.tracks.map(entry),
                searchFolders: library.2.folders.map(folder),
                favourites: library.3.map(entry),
                playback: .init(
                    path: video?.track.relativePath ?? player.current?.relativePath,
                    playing: video?.playing ?? player.isPlaying,
                    elapsed: video?.elapsed ?? player.elapsed,
                    duration: video?.duration ?? player.trackDuration,
                    volume: video?.volume ?? player.volume,
                    shuffle: player.isShuffling, repeating: player.isLooping),
                selected: accounts.selected.rawValue,
                spotify: .init(
                    connected: spotify.connected, connecting: spotify.connecting,
                    account: spotify.account, title: spotify.title, uri: spotify.uri,
                    artist: spotify.artist, album: spotify.album, artworkURL: spotify.artworkURL,
                    playing: spotify.playing, elapsed: spotify.elapsed, duration: spotify.duration,
                    volume: spotify.volume, error: spotify.error,
                    hasSavedAccount: spotify.hasSavedAccount, disconnecting: spotify.disconnecting),
                youtubeConnecting: accounts.youtubeConnecting, youtubeError: accounts.youtubeError,
                youtubeConnected: accounts.youtubeConnected,
                restorePending: SharedDefaults.store.integer(
                    forKey: MusicBackupProvider.restorePendingKey),
                events: events.filter { $0.sequence > query.cursor }, cursor: sequence,
                privacy: MusicPrivacyState.shared.active,
                videoControl: video?.control,
                folderIntent: MusicHostNavigation.folderIntent,
                preferences: .init(
                    crossfade: SharedDefaults.store.object(forKey: MusicFade.enabledKey) as? Bool
                        ?? true,
                    fadeLength: SharedDefaults.store.object(forKey: MusicFade.secondsKey) as? Double
                        ?? 2,
                    barCollapsed: SharedDefaults.store.bool(
                        forKey: AppStorageKeys.Music.barCollapsed),
                    barAutoHide: SharedDefaults.store.bool(
                        forKey: AppStorageKeys.Music.barAutoHide),
                    gridView: SharedDefaults.store.bool(forKey: AppStorageKeys.Music.gridView)),
                tools: .init(
                    installed: MusicTools.shared.installed,
                    installing: MusicTools.shared.installing, error: MusicTools.shared.error))
            return try JSONEncoder().encode(state)
        case "music.ui.action":
            let action = try JSONDecoder().decode(MusicUIAction.self, from: payload)
            try action.validate()
            try await perform(action)
            return Data("{}".utf8)
        case "music.ui.artwork", "music.ui.duration", "music.ui.count", "music.ui.source":
            let action = try JSONDecoder().decode(MusicUIAction.self, from: payload)
            try action.validate()
            if operation == "music.ui.count" {
                _ = try MusicLibrary.folder(at: action.path)
                return try JSONEncoder().encode(TrackMeta.trackCount(under: action.path))
            }
            let track = try MusicLibrary.track(at: action.path)
            if operation == "music.ui.artwork" {
                guard let image = await TrackMeta.artwork(for: track) else {
                    return try JSONEncoder().encode(Data())
                }
                return try JSONEncoder().encode(MusicWorker.thumbnail(image)?.data ?? Data())
            }
            if operation == "music.ui.duration" {
                return try JSONEncoder().encode(await TrackMeta.durationLabel(for: track))
            }
            if operation == "music.ui.source" {
                return try JSONEncoder().encode(
                    YoutubeDownloader.shared.sourceURL(
                        forFileNamed: (action.path as NSString).lastPathComponent))
            }
            return try JSONEncoder().encode(TrackMeta.trackCount(under: action.path))
        case "music.ui.video.open":
            let action = try JSONDecoder().decode(MusicUIAction.self, from: payload)
            try action.validate()
            try openVideo(action.path)
            return try JSONEncoder().encode(video!.lease)
        case "music.ui.video.range":
            guard payload.count <= 2048, let video else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                await video.read(JSONDecoder().decode(MusicVideoRange.self, from: payload)))
        case "music.ui.video.update":
            guard payload.count <= 2048, let video else { throw ExtensionPeerError.invalidRequest }
            try video.report(JSONDecoder().decode(MusicVideoReport.self, from: payload))
            videoActivity = Date()
            worker.player.presentationDidChange()
            return Data("{}".utf8)
        case "music.ui.video.close":
            guard payload.count <= 2048 else { throw ExtensionPeerError.invalidRequest }
            let lease = try JSONDecoder().decode(MusicVideoLease.self, from: payload)
            guard let video, video.lease.id == lease.id, video.lease.revision == lease.revision
            else {
                throw ExtensionPeerError.invalidRequest
            }
            closeVideo()
            return Data("{}".utf8)
        case "music.ui.profiles":
            let profiles = try await Task.detached { try MusicBrowserConnection.profiles() }.value
            try Task.checkCancellation()
            return try JSONEncoder().encode(
                profiles.map { MusicUIProfile(id: $0.id, name: $0.name) })
        case "music.ui.youtube.open":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(await browser.open())
        case "music.ui.youtube.sync":
            guard payload.count <= 20_480 else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                browser.sync(JSONDecoder().decode(MusicBrowserReport.self, from: payload)))
        case "music.ui.youtube.close":
            guard payload.count <= 256 else { throw ExtensionPeerError.invalidRequest }
            try browser.close(JSONDecoder().decode(MusicBrowserToken.self, from: payload))
            return Data("{}".utf8)
        case "music.ui.youtube.external":
            guard payload.count <= 4096,
                let request = try JSONSerialization.jsonObject(with: payload) as? [String: String],
                Set(request.keys) == ["id", "revision", "url"],
                let id = UUID(uuidString: request["id"] ?? ""),
                let revision = UUID(uuidString: request["revision"] ?? ""),
                let url = URL(string: request["url"] ?? ""), url.scheme == "https",
                url.user == nil, url.password == nil, url.port == nil
            else { throw ExtensionPeerError.invalidRequest }
            try browser.validate(.init(id: id, revision: revision))
            guard NSWorkspace.shared.open(url) else { throw ExtensionPeerError.unavailable }
            return Data("{}".utf8)
        case "music.ui.spotify":
            guard let command = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                let action = command["action"] as? String,
                [
                    "toggle", "play", "pause", "next", "previous", "seek", "volume", "shuffle",
                    "repeat", "authorizeLibrary", "catalog", "queueAdd", "setSaved",
                    "createPlaylist",
                ].contains(action),
                Set(command.keys).isSubset(of: [
                    "action", "uri", "index", "milliseconds", "value", "mode", "kind", "requestId",
                    "query", "id", "offset", "limit", "cursor", "saved", "name",
                ]), payload.count <= 16_384
            else { throw ExtensionPeerError.invalidRequest }
            if let uri = command["uri"] as? String, MusicProvider.spotifyURI(uri) == nil {
                throw ExtensionPeerError.invalidRequest
            }
            worker.accounts.spotify.send(command)
            return Data("{}".utf8)
        case "music.ui.streamingArtwork":
            let url = try JSONDecoder().decode(URL.self, from: payload)
            guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
                [
                    "i.scdn.co", "mosaic.scdn.co", "image-cdn-ak.spotifycdn.com",
                    "image-cdn-fa.spotifycdn.com",
                ].contains(url.host ?? ""),
                url.host != "i.scdn.co" || url.path.hasPrefix("/image/")
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(
                try await worker.streamingThumbnail(url)?.data ?? Data())
        case "music.cli":
            return try JSONEncoder().encode(
                await MusicCLIExecution.run(
                    JSONDecoder().decode(ExtensionCLIRequest.self, from: payload),
                    read: { [weak self] in
                        self?.playbackSnapshot() ?? PlayerSnapshot(player: .builtin)
                    },
                    send: { [weak self] in self?.transport($0) }, refresh: worker.player.rescan,
                    renamed: worker.player.renameCurrent))
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private func perform(_ action: MusicUIAction) async throws {
        let player = worker.player
        switch action.kind {
        case .playPause: if let video { video.toggle() } else { player.perform(.toggle) }
        case .pause: if let video { video.pause() } else { player.perform(.pause) }
        case .resume: if let video { video.resume() } else { player.perform(.play) }
        case .next: closeVideo(); player.perform(.next)
        case .previous: closeVideo(); player.perform(.previous)
        case .seek:
            if let video {
                video.seek(try fraction(action))
            } else {
                player.perform(.seek(try fraction(action)))
            }
        case .volume:
            if let video {
                video.setVolume(try fraction(action))
            } else {
                player.perform(.volume(try fraction(action)))
            }
        case .shuffle: player.perform(.shuffle(!player.isShuffling))
        case .repeating: player.perform(.repeat(!player.isLooping))
        case .startTrack:
            _ = try MusicLibrary.track(at: action.path)
            player.perform(.startTrack(action.path))
        case .startFolder:
            _ = try MusicLibrary.folder(at: action.path)
            player.perform(.startSource(.folder(action.path)))
        case .startFavourites:
            player.perform(
                .startSource(.favourites, start: action.path.isEmpty ? nil : action.path))
        case .favourite:
            let track = try MusicLibrary.track(at: action.path)
            _ = MusicLibraryOperationExecution.setFavourite(
                Favourites.contains(track.relativePath) ? .unfavorite : .favorite, path: action.path
            )
        case .createFolder:
            _ = try MusicLibraryContentOperationExecution.createFolder(
                named: action.target, under: action.path)
        case .move:
            let track = try MusicLibrary.track(at: action.path)
            let move = try MusicLibraryContentOperationExecution.move(track, to: action.target)
            player.renameCurrent(move.from, move.to)
        case .rename, .renameFolder:
            let target: MusicLibraryRenameTarget =
                action.kind == .rename
                ? .track(try MusicLibrary.track(at: action.path))
                : .folder(try MusicLibrary.folder(at: action.path))
            let move = try MusicLibraryContentOperationExecution.rename(target, to: action.target)
            player.renameCurrent(move.from, move.to)
        case .delete, .deleteFolder:
            let target: MusicLibraryRemovalTarget =
                action.kind == .delete
                ? .track(try MusicLibrary.track(at: action.path))
                : .folder(try MusicLibrary.folder(at: action.path))
            try MusicLibraryContentOperationExecution.remove(target)
        case .chooseLibrary:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.prompt = "Choose"
            panel.message = "Choose your music folder"
            libraryPanel = panel
            defer { libraryPanel = nil }
            let response = await withTaskCancellationHandler {
                await panel.begin()
            } onCancel: {
                Task { @MainActor in panel.cancel(nil) }
            }
            try Task.checkCancellation()
            guard !stopped else { throw ExtensionPeerError.unavailable }
            guard response == .OK, let url = panel.url else { return }
            _ = try MusicFolderSelectionOperationExecution.select(url.path)
        case .openLibrary: _ = try MusicLibraryOperationExecution.openLibrary()
        case .reveal:
            MusicLibraryOperationExecution.reveal(try MusicLibrary.track(at: action.path).url)
        case .revealFolder:
            MusicLibraryOperationExecution.reveal(try MusicLibrary.folder(at: action.path).url)
        case .openDownloads: try await MusicHostNavigation.open(section: "downloads")
        case .openMusic:
            guard ["", "folder"].contains(action.target) else {
                throw ExtensionPeerError.invalidRequest
            }
            try await MusicHostNavigation.open(
                path: action.path.isEmpty && action.target != "folder" ? nil : action.path)
        case .openSource:
            let track = try MusicLibrary.track(at: action.path)
            guard
                let url = YoutubeDownloader.shared.sourceURL(
                    forFileNamed: track.url.lastPathComponent), url.scheme == "https",
                NSWorkspace.shared.open(url)
            else { throw ExtensionPeerError.invalidRequest }
        case .selectProvider:
            guard let provider = MusicProvider(rawValue: action.target) else {
                throw ExtensionPeerError.invalidRequest
            }
            browser.revoke()
            worker.accounts.select(provider)
        case .connectSpotify: worker.accounts.spotify.connect()
        case .disconnectSpotify: await worker.accounts.spotify.disconnect()
        case .cancelSpotify: worker.accounts.spotify.stop()
        case .connectYoutube:
            let profiles = try await Task.detached { try MusicBrowserConnection.profiles() }.value
            guard let profile = profiles.first(where: { $0.id == action.target }) else {
                throw ExtensionPeerError.invalidRequest
            }
            browser.revoke()
            await worker.accounts.connectYoutube(profile)
        case .disconnectYoutube: browser.revoke(); await worker.accounts.disconnectYoutube()
        case .reloadYoutube:
            worker.accounts.youtubeError = nil; try browser.send("reload")
        case .openChrome:
            guard
                let chrome = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: "com.google.Chrome")
            else { throw ExtensionPeerError.unavailable }
            if !action.target.isEmpty {
                let profiles = try await Task.detached { try MusicBrowserConnection.profiles() }
                    .value
                guard profiles.contains(where: { $0.id == action.target }) else {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            let configuration = NSWorkspace.OpenConfiguration()
            if !action.target.isEmpty {
                configuration.arguments = ["--profile-directory=\(action.target)"]
            }
            _ = try await NSWorkspace.shared.open(
                [MusicProvider.youtubeMusic.homeURL!], withApplicationAt: chrome,
                configuration: configuration)

        case .videoOpen: try openVideo(action.path)
        case .videoClose:
            if video?.track.relativePath == action.path { closeVideo() }
        case .crossfade, .barCollapsed, .barAutoHide, .gridView:
            let value = try fraction(action)
            guard value == 0 || value == 1 else { throw ExtensionPeerError.invalidRequest }
            let key: String
            switch action.kind {
            case .crossfade: key = MusicFade.enabledKey
            case .barCollapsed: key = AppStorageKeys.Music.barCollapsed
            case .barAutoHide: key = AppStorageKeys.Music.barAutoHide
            default: key = AppStorageKeys.Music.gridView
            }
            SharedDefaults.store.set(value == 1, forKey: key)
        case .fadeLength:
            guard let value = action.value, MusicFade.secondsRange.contains(value) else {
                throw ExtensionPeerError.invalidRequest
            }
            SharedDefaults.store.set(value, forKey: MusicFade.secondsKey)
        case .installTool:
            guard MusicTools.names.contains(action.target) else {
                throw ExtensionPeerError.invalidRequest
            }
            MusicTools.shared.install(action.target)
        case .refreshTools:
            MusicTools.shared.refresh(); YoutubeDownloader.shared.checkAvailability()

        }
        try Task.checkCancellation()
        if [.createFolder, .move, .rename, .delete, .renameFolder, .deleteFolder, .chooseLibrary]
            .contains(action.kind)
        {
            TrackMeta.invalidateCaches(); player.rescan()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        MusicHostNavigation.reset()
        browser.stop()
        libraryPanel?.cancel(nil); libraryPanel = nil
        downloads?.stop(); downloads = nil; resumeAudio = false; closeVideo()
        worker.accounts.spotify.receiveUIEvent = nil
        events.removeAll()
    }

    private func playbackSnapshot() -> PlayerSnapshot {
        let player = worker.player
        return PlayerSnapshot(
            player: .builtin, isRunning: true, isPlaying: video?.playing ?? player.isPlaying,
            title: (video?.track ?? player.current).map {
                ($0.relativePath as NSString).lastPathComponent
            } ?? "",
            elapsedSeconds: video?.elapsed ?? player.elapsed,
            durationSeconds: video?.duration ?? player.trackDuration,
            volume: video?.volume ?? player.volume,
            trackPath: video?.track.relativePath ?? player.current?.relativePath)
    }

    private func transport(_ request: MusicTransportRequest) {
        guard let video else { worker.player.perform(request); return }
        switch request {
        case .play: video.resume()
        case .pause: video.pause()
        case .toggle: video.toggle()
        case .stop: video.pause(); video.seek(0)
        case .seek(let value): video.seek(value)
        case .volume(let value): video.setVolume(value)
        case .status: break
        case .shuffle, .repeat: worker.player.perform(request)
        default: closeVideo(); worker.player.perform(request)
        }
    }

    private func openVideo(_ path: String) throws {
        let track = try MusicLibrary.track(at: path)
        guard track.isVideo else { throw ExtensionPeerError.invalidRequest }
        closeVideo()
        let player = worker.player
        let wasPlaying = player.isPlaying
        let next = try MusicVideoPlayback(
            track: track, position: player.current?.relativePath == path ? player.elapsed : 0,
            playing: wasPlaying, volume: player.volume)
        resumeAudio = wasPlaying
        player.perform(.pause)
        video = next; worker.videoPresentation = next
        worker.player.presentationDidChange()
        videoActivity = Date()
        videoDeadline = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !self.stopped, self.video?.lease.id == next.lease.id else { return }
                if Date().timeIntervalSince(self.videoActivity) >= 10 { self.closeVideo(); return }
            }
        }
    }

    private func closeVideo() {
        videoDeadline?.cancel(); videoDeadline = nil
        guard let video else { return }
        let position = video.duration > 0 ? video.elapsed / video.duration : 0
        let same = worker.player.current?.relativePath == video.track.relativePath
        video.stop(); self.video = nil; worker.videoPresentation = nil
        worker.player.presentationDidChange()
        if same { worker.player.perform(.seek(position)) }
        if resumeAudio { worker.player.perform(.play) }
        resumeAudio = false
    }

    private func fraction(_ action: MusicUIAction) throws -> Double {
        guard let value = action.value, (0...1).contains(value) else {
            throw ExtensionPeerError.invalidRequest
        }
        return value
    }
}
