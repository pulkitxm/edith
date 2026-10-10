import AppKit
import EdithExtensionSupport
import Foundation
import EdithExtensionUI
import WebKit

@MainActor final class MusicUIService {
    private let worker: MusicWorker
    private var downloads: MusicDownloadsService?
    private var libraryPanel: NSOpenPanel?

    private var events: [MusicUIEvent] = []
    private var sequence = 0
    private var video: MusicVideoPlayback?
    private var resumeAudio = false
    private var stopped = false
    init(worker: MusicWorker) {
        self.worker = worker
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
        case "music.ui.video.frame":
            let action = try JSONDecoder().decode(MusicUIAction.self, from: payload)
            try action.validate()
            guard let video, video.track.relativePath == action.path else {
                throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(await video.frame())
        case "music.ui.profiles":
            let profiles = try await Task.detached { try MusicBrowserConnection.profiles() }.value
            try Task.checkCancellation()
            return try JSONEncoder().encode(
                profiles.map { MusicUIProfile(id: $0.id, name: $0.name) })
        case "music.ui.youtube.frame":
            let request = try JSONDecoder().decode(MusicUIFrameRequest.self, from: payload)
            guard request.width.isFinite, request.height.isFinite,
                (100...2560).contains(request.width), (100...1440).contains(request.height),
                let view = worker.accounts.youtubeView
            else { throw ExtensionPeerError.invalidRequest }
            view.frame.size = NSSize(width: request.width, height: request.height)
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: min(1280, request.width))
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                view.takeSnapshot(with: configuration) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? ExtensionPeerError.unavailable)
                    }
                }
            }
            try Task.checkCancellation()
            let bytes =
                image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(
                    using: .jpeg, properties: [.compressionFactor: 0.65]) ?? Data()
            guard bytes.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(bytes)
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
                    player: worker.player))
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
            try await MusicHostNavigation.open(path: action.path.isEmpty ? nil : action.path)
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
            worker.accounts.select(provider)
        case .connectSpotify: worker.accounts.spotify.connect()
        case .disconnectSpotify: await worker.accounts.spotify.disconnect()
        case .cancelSpotify: worker.accounts.spotify.stop()
        case .connectYoutube:
            let profiles = try await Task.detached { try MusicBrowserConnection.profiles() }.value
            guard let profile = profiles.first(where: { $0.id == action.target }) else {
                throw ExtensionPeerError.invalidRequest
            }
            await worker.accounts.connectYoutube(profile)
        case .disconnectYoutube: await worker.accounts.disconnectYoutube()
        case .reloadYoutube:
            worker.accounts.youtubeError = nil; worker.accounts.youtubeView?.reload()
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

        case .videoOpen:
            let track = try MusicLibrary.track(at: action.path)
            guard track.isVideo else { throw ExtensionPeerError.invalidRequest }
            if video?.track.relativePath == action.path { return }
            closeVideo()
            resumeAudio = player.isPlaying
            let position = player.current?.relativePath == action.path ? player.elapsed : 0
            player.perform(.pause)
            video = MusicVideoPlayback(
                track: track, position: position, playing: resumeAudio, volume: player.volume)
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
        libraryPanel?.cancel(nil); libraryPanel = nil
        downloads?.stop(); downloads = nil; resumeAudio = false; closeVideo()
        worker.accounts.spotify.receiveUIEvent = nil
        events.removeAll()
    }

    private func closeVideo() {
        guard let video else { return }
        let position = video.duration > 0 ? video.elapsed / video.duration : 0
        let same = worker.player.current?.relativePath == video.track.relativePath
        video.stop(); self.video = nil
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
