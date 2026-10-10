import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicEmbeddedUITests {
    private func state(title: String = "Mock Garden") -> EmbeddedMusicUIState {
        let root = URL(fileURLWithPath: "/tmp/mock-music-library")
        let entry = EmbeddedMusicUIEntry(
            path: title + ".wav", url: root.appendingPathComponent(title + ".wav"))
        return EmbeddedMusicUIState(
            root: root, tracks: [entry], folders: [], folderTracks: [entry], searchTracks: [],
            searchFolders: [], favourites: [entry],
            playback: .init(
                path: entry.path, playing: true, elapsed: 12, duration: 100, volume: 0.5,
                shuffle: false, repeating: true),
            selected: "local",
            spotify: .init(
                connected: false, connecting: false, account: "", title: "", uri: "", artist: "",
                album: "", playing: false, elapsed: 0, duration: 0, volume: 0.7),
            youtubeConnecting: false, youtubeConnected: false, restorePending: 0, events: [],
            cursor: 0, privacy: false)
    }

    @Test func facadeReadsOwnedModelsAndSendsFixedActions() async throws {
        let remote = EmbeddedMusicRemote()
        let encoded = try JSONEncoder().encode(state())
        var actions: [EmbeddedMusicUIAction] = []
        remote.configure { operation, payload in
            if operation == "music.ui.read" { return encoded }
            #expect(operation == "music.ui.action")
            actions.append(try JSONDecoder().decode(EmbeddedMusicUIAction.self, from: payload))
            return Data("{}".utf8)
        }
        defer { remote.stop() }
        remote.rescan()
        for _ in 0..<20 where !remote.entriesLoaded { await Task.yield() }
        #expect(remote.current?.title == "Mock Garden")
        #expect(remote.favouritePaths == ["Mock Garden.wav"])
        #expect(remote.looping)
        remote.seek(to: 0.5)
        for _ in 0..<20 where actions.isEmpty { await Task.yield() }
        #expect(actions.first?.kind == .seek)
        #expect(actions.first?.value == 0.5)
        remote.stop()
        #expect(remote.duration == 0)
        #expect(remote.elapsed == 0)
        #expect(remote.volume == 0.7)
        #expect(!remote.looping)
        #expect(remote.restorePending == 0)
        #expect(EmbeddedTrackMeta.root.path == "/")
    }

    @Test func stopRejectsLateResponsesAndCancelsLocalTasks() async throws {
        let remote = EmbeddedMusicRemote()
        let encoded = try JSONEncoder().encode(state())
        var pending: CheckedContinuation<Data, Error>?
        remote.configure { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        remote.rescan()
        for _ in 0..<20 where pending == nil { await Task.yield() }
        #expect(pending != nil)
        remote.stop()
        pending?.resume(returning: encoded)
        for _ in 0..<20 { await Task.yield() }
        #expect(remote.tracks.isEmpty)
        #expect(!remote.entriesLoaded)
        #expect(!remote.isPlaying)
    }

    @Test func invalidSnapshotIsRejectedAndConcurrentScenesShareOneRead() async throws {
        let remote = EmbeddedMusicRemote()
        var invalid = state()
        invalid.playback.volume = 2
        let invalidData = try JSONEncoder().encode(invalid)
        remote.configure { _, _ in invalidData }
        remote.rescan()
        for _ in 0..<20 where remote.libraryError == nil { await Task.yield() }
        #expect(remote.libraryError != nil)
        #expect(remote.tracks.isEmpty)
        var pending: CheckedContinuation<Data, Error>?
        var reads = 0
        let encoded = try JSONEncoder().encode(state())
        remote.configure { _, _ in
            reads += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        remote.rescan()
        for _ in 0..<20 where pending == nil { await Task.yield() }
        remote.rescan(); remote.rescan()
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 1)
        pending?.resume(returning: encoded)
        for _ in 0..<20 where !remote.entriesLoaded { await Task.yield() }
        #expect(remote.current?.title == "Mock Garden")
        remote.stop()
    }

    @Test func downloadFacadePreservesQueueActionsAndRejectsStaleOrLateState() async throws {
        let remote = EmbeddedMusicRemote.shared
        let downloader = EmbeddedYoutubeDownloader.shared
        let id = UUID()
        let record = EmbeddedDownloadRecord(
            id: id, url: URL(string: "https://youtu.be/mock-garden")!,
            status: .error("Mock interrupted"), outputFilename: nil, createdAt: Date(), kind: .audio
        )
        let generation = UUID()
        let value = EmbeddedMusicDownloadsState(
            snapshot: .init(
                records: [record], logs: [id.uuidString: "Mock log"], enabled: true, running: false,
                generation: generation, revision: 2), updating: false,
            directories: ["audio": URL(fileURLWithPath: "/tmp/mock-audio")])
        var actions: [EmbeddedMusicDownloadAction] = []
        let encoded = try JSONEncoder().encode(value)
        remote.configure { operation, payload in
            if operation == "music.ui.downloads.read" { return encoded }
            #expect(operation == "music.ui.downloads.action")
            actions.append(
                try JSONDecoder().decode(EmbeddedMusicDownloadAction.self, from: payload))
            return Data("{}".utf8)
        }
        defer { remote.stop() }
        await downloader.refresh()
        let item = try #require(downloader.items.first)
        #expect(item.logs == "Mock log")
        #expect(item.record.canRetry)
        downloader.retry(item)
        for _ in 0..<20 where actions.isEmpty { await Task.yield() }
        #expect(actions.first?.kind == .retry)
        #expect(actions.first?.id == id)
        var old = value
        old.snapshot = .init(
            records: [], logs: [:], enabled: true, running: false, generation: generation,
            revision: 1)
        try downloader.apply(old)
        #expect(downloader.items.count == 1)
        var pending: CheckedContinuation<Data, Error>?
        remote.configure { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let read = Task { await downloader.refresh() }
        for _ in 0..<20 where pending == nil { await Task.yield() }
        remote.stop()
        pending?.resume(returning: encoded)
        await read.value
        #expect(downloader.items.isEmpty)
    }

    @Test func waveformUsesCheckedEngineLevelsAndDropsLateFramesOnStop() async throws {
        let remote = EmbeddedMusicRemote.shared
        let levels = EmbeddedPlaybackLevel.shared
        remote.configure { operation, _ in
            #expect(operation == "music.ui.level")
            return try JSONEncoder().encode(0.25)
        }
        levels.attachViewer()
        defer { levels.detachViewer(); remote.stop() }
        for _ in 0..<20 where levels.level != 0.25 { await Task.yield() }
        #expect(levels.level == 0.25)
        var pending: CheckedContinuation<Data, Error>?
        remote.configure { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        for _ in 0..<20 where pending == nil { await Task.yield() }
        remote.stop()
        pending?.resume(returning: try JSONEncoder().encode(0.9))
        for _ in 0..<20 { await Task.yield() }
        #expect(levels.level == EmbeddedPlaybackLevel.neutral)
        remote.configure { _, _ in try JSONEncoder().encode(2.0) }
        for _ in 0..<20 where remote.libraryError == nil { await Task.yield() }
        #expect(remote.libraryError != nil)
        #expect(levels.level == EmbeddedPlaybackLevel.neutral)
    }

    @Test func originalEmbeddedControllersRenderAtBothWidthsThemesAndZoom() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let remote = EmbeddedMusicRemote.shared
        let encoded = try JSONEncoder().encode(state())
        remote.configure { _, _ in encoded }
        remote.rescan()
        for _ in 0..<20 where !remote.entriesLoaded { await Task.yield() }
        let current = try #require(remote.current)
        EmbeddedMusicDetailPresenter.shared.show(current)
        #expect(EmbeddedMusicDetailPresenter.shared.track == current)
        let fixtureDirectory = URL(
            fileURLWithPath: "/tmp/extension-final-batch-20261010/music-render-fixtures")
        try FileManager.default.createDirectory(
            at: fixtureDirectory, withIntermediateDirectories: true)
        let defaults = SharedDefaults.store
        let priorZoom = defaults.object(forKey: WindowZoom.defaultsKey)
        defer {
            remote.stop(); defaults.set(priorZoom, forKey: WindowZoom.defaultsKey); UIScale.apply(1)
        }
        for width in [540.0, 960.0] {
            for scheme in [ColorScheme.light, .dark] {
                for zoom in [1.0, 1.5] {
                    defaults.set(zoom, forKey: WindowZoom.defaultsKey)
                    UIScale.apply(zoom)
                    let home = NSHostingController(
                        rootView: ExtensionPageHost {
                            EmbeddedMusicSceneLoad {
                                EmbeddedMusicHomeScene(tile: SurfaceTile(.music))
                            }
                        })
                    let downloads = NSHostingController(
                        rootView: ExtensionPageHost { EmbeddedDownloadSheet() })
                    let controllers: [(String, NSViewController)] =
                        try EmbeddedMusicSceneRoute.allCases.map { route in
                            let state = ExtensionPresentationState(
                                compact: width < 720, visible: false,
                                availableWidth: width,
                                intrinsic: [.footer, .sidebar].contains(route))
                            return (
                                route.rawValue,
                                try #require(
                                    state.withContext {
                                        EmbeddedMusicAuxiliaryScenes.controller([
                                            "location": route.rawValue, "section": "music",
                                        ])
                                    })
                            )
                        } + [("home", home), ("downloads", downloads)]
                    for (location, controller) in controllers {
                        controller.view.frame = CGRect(
                            x: 0, y: 0, width: width,
                            height: ["main", "downloads", "music.detail", "settings"].contains(
                                location) ? 800 : 300)
                        controller.view.appearance = NSAppearance(
                            named: scheme == .dark ? .darkAqua : .aqua)
                        let container = MusicRenderFixtureView(frame: controller.view.frame)
                        container.color =
                            scheme == .dark
                            ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor.white
                        container.addSubview(controller.view)
                        controller.view.autoresizingMask = [.width, .height]
                        try await Task.sleep(for: .milliseconds(100))
                        controller.view.layoutSubtreeIfNeeded()
                        #expect(UIScale.current == zoom)
                        #expect(EmbeddedMusicDetailPresenter.shared.track == current)
                        let bitmap: NSBitmapImageRep
                        if location == "music.footer" {
                            let renderer = ImageRenderer(
                                content:
                                    EmbeddedMusicFooterScene()
                                    .environment(\.colorScheme, scheme)
                                    .frame(width: width, height: 96 * zoom)
                                    .background(scheme == .dark ? Color(white: 0.12) : .white))
                            renderer.scale = 2
                            let image = try #require(renderer.nsImage)
                            let imageData = try #require(image.tiffRepresentation)
                            bitmap = try #require(NSBitmapImageRep(data: imageData))
                        } else {
                            bitmap = try #require(
                                container.bitmapImageRepForCachingDisplay(in: container.bounds))
                            container.cacheDisplay(in: container.bounds, to: bitmap)
                        }
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        #expect(png.count > 100)
                        var colors = Set<String>()
                        for x in stride(
                            from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 20))
                        {
                            for y in stride(
                                from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 20))
                            {
                                if let color = bitmap.colorAt(x: x, y: y) {
                                    colors.insert(color.description)
                                }
                            }
                        }
                        #expect(
                            colors.count > 3,
                            "The \(location) controller must render visible content.")
                        let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")-\(zoom)"
                        try png.write(
                            to: fixtureDirectory.appendingPathComponent(
                                location + "-" + suffix + ".png"))
                        #expect(controller.view.window == nil)
                        controller.view.removeFromSuperview()
                        #expect(controller.view.fittingSize.width.isFinite)
                        #expect(controller.view.fittingSize.height.isFinite)
                    }
                }
            }
        }
        remote.stop()
        #expect(EmbeddedMusicDetailPresenter.shared.track == nil)
    }
}

private final class MusicRenderFixtureView: NSView {
    var color = NSColor.white
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
