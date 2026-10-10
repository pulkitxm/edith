import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit
#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif

@MainActor struct MusicWorkerResources {
    let player: LocalMusicPlayer
    let external: ExternalMusic
    let accounts: MusicAccounts
    let session: URLSession

    static func live(
        player: LocalMusicPlayer? = nil, external: ExternalMusic? = nil,
        accounts: MusicAccounts? = nil
    ) -> Self {
        Self(
            player: player ?? LocalMusicPlayer(), external: external ?? ExternalMusic(),
            accounts: accounts ?? .shared, session: URLSession(configuration: .ephemeral))
    }
}

@MainActor
final class MusicWorker {
    private let fixture: WorkerFixtureAdmission?
    private let resources: MusicWorkerResources?
    var isInertFixture: Bool { fixture != nil }
    var liveDependencyCount: Int { resources == nil ? 0 : 4 }
    var player: LocalMusicPlayer {
        guard let resources else {
            preconditionFailure("Playback is unavailable in Music lifecycle fixtures.")
        }
        return resources.player
    }
    var external: ExternalMusic {
        guard let resources else {
            preconditionFailure("External playback is unavailable in Music lifecycle fixtures.")
        }
        return resources.external
    }
    var accounts: MusicAccounts {
        guard let resources else {
            preconditionFailure("Accounts are unavailable in Music lifecycle fixtures.")
        }
        return resources.accounts
    }
    private var artwork: [URL: SurfaceThumbnail] = [:]
    private var stopped = false
    private let tasks = MusicTaskOwner()
    var browserPresentation: MusicBrowserPresentation?
    var videoPresentation: MusicVideoPlayback?

    convenience init(
        context: NSDictionary, roleBundle: Bundle,
        validateProduction: @escaping @MainActor () throws -> Void = {}
    ) throws {
        try self.init(
            admission: {
                try Self.resolveFixture(
                    admission: {
                        try WorkerFixtureAdmission.current(
                            extensionID: "music", context: context, roleBundle: roleBundle)
                    },
                    applicationIdentifier: ProcessInfo.processInfo.environment[
                        "EDITH_APPLICATION_IDENTIFIER"])
            },
            makeLiveResources: {
                try validateProduction()
                return MusicWorkerResources.live()
            })
    }

    init(
        admission: () throws -> WorkerFixtureAdmission?,
        makeLiveResources: (@MainActor () throws -> MusicWorkerResources)? = nil,
        startImmediately: Bool = true
    ) throws {
        let fixture = try Self.resolveFixture(admission: admission)
        self.fixture = fixture
        if fixture == nil {
            resources = try makeLiveResources?() ?? MusicWorkerResources.live()
        } else {
            resources = nil
        }
        guard let resources else { return }
        resources.accounts.presentationOwnedYoutube = true
        if startImmediately {
            resources.accounts.activate()
            resources.external.start()
            tasks.start { try? await DownloadWorker.shared.start() }
        }
    }

    static func resolveFixture(
        admission: () throws -> WorkerFixtureAdmission?, applicationIdentifier: String? = nil
    ) throws -> WorkerFixtureAdmission? {
        let fixture = try admission()
        if fixture == nil, applicationIdentifier?.hasPrefix("com.pulkit.edith.tests.") == true {
            throw WorkerFixtureError.invalid
        }
        if let fixture {
            guard fixture.extensionID == "music", fixture.role == .app,
                let mode = try FileManager.default.attributesOfItem(
                    atPath: fixture.home.deletingLastPathComponent().path)[.posixPermissions]
                    as? NSNumber,
                mode.intValue == 0o700
            else { throw WorkerFixtureError.invalid }
        }
        return fixture
    }

    func read(_ tile: SurfaceTile) async throws -> [MusicSurfacePlayback] {
        guard !stopped, !isInertFixture else { throw ExtensionPeerError.unavailable }
        var result: [MusicSurfacePlayback] = []
        let track = videoPresentation?.track ?? player.current
        var local = MusicSurfacePlayback(
            sourceID: "local", sourceTitle: "Local library", trackKey: track?.relativePath ?? "",
            title: track?.title ?? "", playing: videoPresentation?.playing ?? player.isPlaying,
            elapsed: videoPresentation?.elapsed ?? player.elapsed,
            duration: videoPresentation?.duration ?? player.trackDuration,
            volume: videoPresentation?.volume ?? player.volume, shuffle: player.isShuffling,
            repeating: player.isLooping)
        if tile.shows("queue") {
            local.queue = await player.upcoming(limit: 10).map {
                .init(key: $0.relativePath, title: $0.title)
            }
        }
        if tile.shows("artwork"), tile.sourceIDs?.contains("local") ?? true, let track,
            let image = await TrackMeta.artwork(for: track), !Task.isCancelled
        {
            local.thumbnail = Self.thumbnail(image)
        }
        result.append(local)
        let spotify = accounts.spotify
        if spotify.connected {
            var value = MusicSurfacePlayback(
                sourceID: "spotify", sourceTitle: "Spotify", trackKey: spotify.uri,
                title: spotify.title, artist: spotify.artist, playing: spotify.playing,
                elapsed: spotify.elapsed, duration: spotify.duration, volume: spotify.volume,
                shuffle: spotify.library.shuffle, repeating: spotify.library.repeatMode != "off")
            if tile.shows("artwork"), tile.sourceIDs?.contains("spotify") ?? true,
                let url = spotify.artworkURL
            {
                value.thumbnail = try await streamingThumbnail(url)
            }
            result.append(value)
        }
        if let metadata = browserPresentation?.metadata { result.append(metadata) }
        if let track = external.current {
            let playback = external.playback
            result.append(
                .init(
                    sourceID: "external." + track.app.rawValue, sourceTitle: track.app.displayName,
                    trackKey: track.title + "\0" + track.artist, title: track.title,
                    artist: track.artist,
                    playing: track.isPlaying, elapsed: playback?.elapsed() ?? 0,
                    duration: track.duration,
                    volume: playback?.volume ?? 0.7, seekable: playback != nil,
                    volumeAvailable: playback != nil,
                    shuffle: playback?.canShuffle == true ? playback?.shuffling : nil,
                    repeating: playback?.canRepeat == true ? playback?.repeating : nil))
        }
        try Task.checkCancellation()
        guard !stopped, !isInertFixture else { throw ExtensionPeerError.unavailable }
        return result
    }

    func readNotch(_ tile: SurfaceTile) async throws -> [MusicSurfacePlayback] {
        guard !stopped, !isInertFixture else { throw ExtensionPeerError.unavailable }
        await external.refreshPresentationPlayback()
        try Task.checkCancellation()
        return try await read(tile)
    }

    func retryNotch(_ tile: SurfaceTile) async throws -> [MusicSurfacePlayback] {
        guard !stopped, !isInertFixture else { throw ExtensionPeerError.unavailable }
        await external.refreshPresentationPlayback(force: true)
        try Task.checkCancellation()
        return try await read(tile)
    }

    func notchAppIcon(_ sourceID: String) -> SurfaceThumbnail? {
        guard !stopped, !isInertFixture else { return nil }
        guard
            let app = ExternalApp.allCases.first(where: {
                sourceID == "external." + $0.rawValue || sourceID == $0.rawValue
            })
        else { return nil }
        if let icon = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID
        ).first?.icon {
            return Self.thumbnail(icon)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        else { return nil }
        return Self.thumbnail(NSWorkspace.shared.icon(forFile: url.path))
    }

    func perform(_ command: MusicSurfaceCommand) async throws {
        guard !stopped, !isInertFixture else { throw ExtensionPeerError.unavailable }
        if ["open", "openPlayer"].contains(command.action) {
            if let app = ExternalApp.allCases.first(where: {
                command.sourceID == "external." + $0.rawValue
            }) {
                guard
                    let url = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: app.bundleID)
                else {
                    throw ExtensionPeerError.unavailable
                }
                _ = try await NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                let path =
                    command.sourceID == "local" && command.action == "open"
                    ? (command.trackKey as NSString).deletingLastPathComponent : nil
                try await MusicHostNavigation.open(
                    path: path, presentationID: command.presentationID,
                    location: command.presentationID == nil ? nil : "notch")
            }
            return
        }
        if command.sourceID == "local" {
            if command.action == "playQueue" {
                guard
                    let track = await player.upcoming(limit: 10).first(where: {
                        $0.relativePath == command.trackKey
                    })
                else { throw ExtensionPeerError.invalidRequest }
                try Task.checkCancellation(); player.perform(.startTrack(track.relativePath));
                return
            }
            guard (videoPresentation?.track ?? player.current)?.relativePath == command.trackKey
            else {
                throw ExtensionPeerError.invalidRequest
            }
            player.perform(
                try transport(
                    command, elapsed: videoPresentation?.elapsed ?? player.elapsed,
                    duration: videoPresentation?.duration ?? player.trackDuration,
                    shuffle: player.isShuffling, repeating: player.isLooping))
        } else if command.sourceID == "spotify" {
            let spotify = accounts.spotify
            guard spotify.connected, spotify.uri == command.trackKey else {
                throw ExtensionPeerError.invalidRequest
            }
            switch command.action {
            case "toggle": spotify.send(["action": "toggle"])
            case "next", "previous": spotify.send(["action": command.action])
            case "backward", "forward": spotify.seek(by: command.action == "backward" ? -15 : 15)
            case "seek":
                spotify.send([
                    "action": "seek",
                    "milliseconds": Int(
                        UnitInterval.clamp(command.value ?? 0) * spotify.duration * 1000),
                ])
            case "volume": spotify.setVolume(command.value ?? 0)
            case "shuffle": spotify.send(["action": "shuffle", "value": !spotify.library.shuffle])
            case "repeat":
                spotify.send([
                    "action": "repeat",
                    "mode": spotify.library.repeatMode == "off" ? "context" : "off",
                ])
            default: throw ExtensionPeerError.invalidRequest
            }
        } else if command.sourceID == "youtubeMusic", let browserPresentation,
            browserPresentation.metadata?.trackKey == command.trackKey
        {
            try browserPresentation.send(command.action, value: command.value)
        } else if let track = external.current,
            command.sourceID == "external." + track.app.rawValue,
            command.trackKey == track.title + "\0" + track.artist
        {
            external.observePlayback(true)
            external.perform(
                try transport(
                    command, elapsed: external.playback?.elapsed() ?? 0,
                    duration: track.duration, shuffle: external.playback?.shuffling ?? false,
                    repeating: external.playback?.repeating ?? false))
        } else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    func shutdown() async {
        stop()
        if !isInertFixture { await DownloadWorker.shared.stop() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let resources else { tasks.shutdown(); return }
        videoPresentation?.stop(); videoPresentation = nil
        browserPresentation?.stop(); browserPresentation = nil
        tasks.shutdown()
        resources.session.invalidateAndCancel(); artwork.removeAll()
        player.shutdown(); external.stop(); accounts.shutdown()
        MusicRemote.shared.stop(); YoutubeDownloader.shared.shutdown(); MusicTools.shared.shutdown()
        MusicPrivacyState.shared.shutdown(); WindowVisibility.shared.shutdown()
        TrackMeta.shutdown()
    }

    private func transport(
        _ command: MusicSurfaceCommand, elapsed: Double, duration: Double,
        shuffle: Bool, repeating: Bool
    ) throws -> MusicTransportRequest {
        switch command.action {
        case "toggle": .toggle
        case "next": .next
        case "previous": .previous
        case "backward": .seek(duration > 0 ? UnitInterval.clamp((elapsed - 15) / duration) : 0)
        case "forward": .seek(duration > 0 ? UnitInterval.clamp((elapsed + 15) / duration) : 0)
        case "seek": .seek(UnitInterval.clamp(command.value ?? 0))
        case "volume": .volume(UnitInterval.clamp(command.value ?? 0))
        case "shuffle": .shuffle(!shuffle)
        case "repeat": .repeat(!repeating)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func streamingThumbnail(_ url: URL) async throws -> SurfaceThumbnail? {
        guard !stopped, let resources else { throw ExtensionPeerError.unavailable }
        if let cached = artwork[url] { return cached }
        let (bytes, response) = try await resources.session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.expectedContentLength <= 1_048_576
        else { return nil }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { return nil }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue > 0, height.doubleValue > 0,
            width.doubleValue * height.doubleValue <= 32_000_000,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary),
            let value = Self.thumbnail(
                NSImage(
                    cgImage: image,
                    size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))))
        else { return nil }
        if artwork.count >= 4 { artwork.removeAll() }
        artwork[url] = value
        return value
    }

    static func thumbnail(_ image: NSImage) -> SurfaceThumbnail? {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 160, height: 160))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 131_072
        else { return nil }
        return SurfaceThumbnail(data: data, accessibilityLabel: "Album artwork", field: "artwork")
    }
}
