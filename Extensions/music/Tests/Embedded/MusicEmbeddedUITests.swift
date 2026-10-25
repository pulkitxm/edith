import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicEmbeddedUITests {
    @Test func folderIntentIsConsumedOnceAndOnlyAfterEngineAcknowledgement() async throws {
        let remote = EmbeddedMusicRemote()
        var value = state()
        var queries: [EmbeddedMusicUIQuery] = []
        var actions: [EmbeddedMusicUIAction] = []
        remote.configure { operation, payload in
            if operation == "music.ui.read" {
                queries.append(try JSONDecoder().decode(EmbeddedMusicUIQuery.self, from: payload))
                return try JSONEncoder().encode(value)
            }
            actions.append(try JSONDecoder().decode(EmbeddedMusicUIAction.self, from: payload))
            return Data("{}".utf8)
        }
        defer { remote.stop() }
        remote.rescan()
        for _ in 0..<50 where !remote.entriesLoaded { await Task.yield() }
        remote.reveal(
            .init(
                url: URL(fileURLWithPath: "/tmp/mock-music-library/Mock Collection/Mock.wav"),
                relativePath: "Mock Collection/Mock.wav"))
        for _ in 0..<50 where actions.isEmpty { await Task.yield() }
        #expect(actions.first?.kind == .openMusic)
        #expect(actions.first?.path == "Mock Collection")
        #expect(actions.first?.target == "folder")
        #expect(remote.folderPath.isEmpty)
        value.folderIntent = .init(revision: 1, path: "Mock Collection")
        remote.rescan(force: true)
        for _ in 0..<50 where remote.folderPath != "Mock Collection" || !remote.entriesLoaded {
            await Task.yield()
        }
        #expect(remote.folderPath == "Mock Collection")
        #expect(queries.last?.path == "Mock Collection")
        remote.navigate(to: "Mock Other")
        for _ in 0..<50 where !remote.entriesLoaded { await Task.yield() }
        #expect(remote.folderPath == "Mock Other")
        var invalid = value
        invalid.folderIntent = .init(revision: 2, path: "../escape")
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid.folderIntent = .init(revision: 0, path: "Mock")
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test func joinedStopBlocksConfigurationUntilEveryOldResponseAndFollowerCompletes() async throws
    {
        let remote = EmbeddedMusicRemote()
        let old = try JSONEncoder().encode(state(title: "Mock Old"))
        let fresh = try JSONEncoder().encode(state(title: "Mock Fresh"))
        var pending: CheckedContinuation<Data, Error>?
        var oldReads = 0
        var blockedReads = 0
        var completed: Set<Int> = []
        var stopping = false
        var following = false
        var first: Task<Void, Never>?
        var follower: Task<Void, Never>?
        remote.configure { _, _ in
            oldReads += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        do {
            remote.rescan()
            try await settle { pending != nil }
            first = Task {
                stopping = true; await remote.stopAndWait(); completed.insert(1)
            }
            try await settle { stopping }
            follower = Task {
                following = true; await remote.stopAndWait(); completed.insert(2)
            }
            try await settle { following }
            remote.configure { _, _ in
                blockedReads += 1; return fresh
            }
            remote.rescan()
            #expect(completed.isEmpty && oldReads == 1 && blockedReads == 0)
            let response = try #require(pending)
            pending = nil
            response.resume(returning: old)
            await first?.value
            await follower?.value
            #expect(completed == [1, 2] && remote.tracks.isEmpty && !remote.entriesLoaded)
            remote.rescan()
            #expect(oldReads == 1 && blockedReads == 0)
            remote.configure { _, _ in fresh }
            remote.rescan()
            try await settle { remote.entriesLoaded }
            #expect(remote.current?.title == "Mock Fresh" && remote.libraryError == nil)
            await remote.stopAndWait()
        } catch {
            let response = pending
            pending = nil
            response?.resume(throwing: CancellationError())
            await first?.value
            await follower?.value
            await remote.stopAndWait()
            throw error
        }
    }

    @Test func aNewSuspensionCannotBeClearedByAnOlderJoinedStop() async throws {
        let remote = EmbeddedMusicRemote()
        let encoded = try JSONEncoder().encode(state())
        var pending: CheckedContinuation<Data, Error>?
        var freshReads = 0
        var stopping = false
        var stop: Task<Void, Never>?
        remote.configure { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        do {
            remote.rescan()
            try await settle { pending != nil }
            stop = Task {
                stopping = true; await remote.stopAndWait()
            }
            try await settle { stopping }
            remote.suspendCommands()
            let response = try #require(pending)
            pending = nil
            response.resume(returning: encoded)
            await stop?.value
            remote.configure { _, _ in
                freshReads += 1; return encoded
            }
            remote.rescan()
            #expect(freshReads == 0 && !remote.entriesLoaded)
            await remote.stopAndWait()
            remote.configure { _, _ in
                freshReads += 1; return encoded
            }
            remote.rescan()
            try await settle { remote.entriesLoaded }
            #expect(freshReads == 1)
            await remote.stopAndWait()
        } catch {
            let response = pending
            pending = nil
            response?.resume(throwing: CancellationError())
            await stop?.value
            await remote.stopAndWait()
            throw error
        }
    }

    @Test func retiredClientCannotReopenOrDetachAFreshConfiguration() async throws {
        let remote = EmbeddedMusicRemote()
        defer { remote.stop() }
        let oldBridge = MusicReconfigurationTestBridge()
        let newBridge = MusicReconfigurationTestBridge()
        let old = try #require(ExtensionEngineClient(bridge: oldBridge, presentationID: UUID()))
        let fresh = try #require(ExtensionEngineClient(bridge: newBridge, presentationID: UUID()))
        remote.configure(old)
        _ = try await remote.dataRequest("music.ui.read")
        await remote.stopAndWait()
        remote.configure(old)
        do {
            _ = try await remote.dataRequest("music.ui.read")
            Issue.record("A retired client admitted a new request")
        } catch ExtensionPeerError.unavailable {} catch { throw error }
        #expect(oldBridge.requests == 1 && newBridge.requests == 0)
        remote.configure(fresh)
        remote.detach(old)
        #expect(try await remote.dataRequest("music.ui.read") == Data("{}".utf8))
        #expect(oldBridge.requests == 1 && newBridge.requests == 1)
        await remote.stopAndWait()
    }

    private func settle(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(ready())
    }

    private func state(title: String = "Mock Garden") -> EmbeddedMusicUIState {
        let root = URL(fileURLWithPath: "/tmp/mock-music-library")
        let entry = EmbeddedMusicUIEntry(
            path: title + ".wav", url: root.appendingPathComponent(title + ".wav"))
        return EmbeddedMusicUIState(
            root: root, folders: [], folderTracks: [entry], favourites: [entry],
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
        for _ in 0..<20 { await Task.yield() }
        #expect(remote.libraryError == nil)
        #expect(!remote.entriesLoaded)
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
        for _ in 0..<20 { await Task.yield() }
        #expect(remote.libraryError == nil)
        #expect(levels.level == EmbeddedPlaybackLevel.neutral)
    }

    @Test func originalEmbeddedControllersRenderAtBothWidthsThemesAndZoom() async throws {
        let application = NSApplication.shared
        let priorPolicy = application.activationPolicy()
        let priorAppearance = application.appearance
        application.setActivationPolicy(.prohibited)
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let priorAccessibility = attributes.map { application.accessibilityAttributeValue($0) }
        for attribute in attributes {
            application.accessibilitySetValue(true, forAttribute: attribute)
        }
        let remote = EmbeddedMusicRemote.shared
        let defaults = SharedDefaults.store
        let keys = [
            WindowZoom.defaultsKey, AppStorageKeys.General.appearance,
            EmbeddedMusicFade.enabledKey, EmbeddedMusicFade.secondsKey,
            AppStorageKeys.Music.barCollapsed, AppStorageKeys.Music.barAutoHide,
            AppStorageKeys.Music.gridView,
        ]
        let priorDefaults = keys.map { defaults.object(forKey: $0) }
        let priorZoom = UIScale.current
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-render-" + UUID().uuidString, isDirectory: true)
        defer {
            remote.stop()
            for (key, value) in zip(keys, priorDefaults) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            UIScale.apply(priorZoom)
            application.appearance = priorAppearance
            for (attribute, value) in zip(attributes, priorAccessibility) {
                application.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
            application.setActivationPolicy(priorPolicy)
            try? FileManager.default.removeItem(at: fixtureDirectory)
            #expect(EmbeddedMusicDetailPresenter.shared.track == nil)
            #expect(remote.tracks.isEmpty && !remote.entriesLoaded)
        }
        try FileManager.default.createDirectory(
            at: fixtureDirectory, withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(state())
        let downloadsState = EmbeddedMusicDownloadsState(
            snapshot: .init(
                records: [], logs: [:], enabled: true, running: false,
                generation: UUID(), revision: 1), updating: false,
            directories: ["audio": fixtureDirectory.appendingPathComponent("audio")])
        let encodedDownloads = try JSONEncoder().encode(downloadsState)
        remote.configure { operation, _ in
            switch operation {
            case "music.ui.read": return encoded
            case "music.ui.downloads.read": return encodedDownloads
            case "music.ui.level": return try JSONEncoder().encode(0.25)
            case "music.ui.action", "music.ui.downloads.action": return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
        remote.rescan()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !remote.entriesLoaded && remote.libraryError == nil && ContinuousClock.now < deadline
        {
            await Task.yield()
        }
        try #require(remote.entriesLoaded && remote.libraryError == nil)
        let current = try #require(remote.current)
        EmbeddedMusicDetailPresenter.shared.show(current)
        await EmbeddedYoutubeDownloader.shared.refresh()
        #expect(EmbeddedMusicDetailPresenter.shared.track == current)
        for width in [540.0, 960.0] {
            for scheme in [ColorScheme.light, .dark] {
                for zoom in [1.0, 1.5] {
                    defaults.set(zoom, forKey: WindowZoom.defaultsKey)
                    UIScale.apply(zoom)
                    defaults.set(
                        scheme == .dark ? "dark" : "light",
                        forKey: AppStorageKeys.General.appearance)
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
                        defer { controller.view.removeFromSuperview() }
                        controller.view.autoresizingMask = [.width, .height]
                        let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")-\(zoom)"
                        let caseName = location + "-" + suffix
                        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                        var bitmap: NSBitmapImageRep?
                        var pixels: MusicRenderPixels?
                        let control = [
                            "music.sidebar": "Show the player bar",
                            "music.footer": "Collapse the player bar",
                        ][location]
                        var controlReady = control == nil
                        repeat {
                            await Task.yield()
                            container.layoutSubtreeIfNeeded()
                            controller.view.layoutSubtreeIfNeeded()
                            controlReady =
                                control.map {
                                    musicRenderHasControl(controller.view, label: $0)
                                } ?? true
                            let next = try #require(
                                container.bitmapImageRepForCachingDisplay(in: container.bounds),
                                Comment(rawValue: caseName))
                            container.cacheDisplay(in: container.bounds, to: next)
                            pixels = try MusicRenderPixels(image: #require(next.cgImage))
                            bitmap = next
                        } while !(pixels?.hasContent == true && controlReady)
                            && ContinuousClock.now < deadline
                        #expect(UIScale.current == zoom, Comment(rawValue: caseName))
                        #expect(EmbeddedMusicDetailPresenter.shared.track == current)
                        #expect(
                            controlReady,
                            Comment(rawValue: caseName + " missing control: " + (control ?? "")))
                        let content = try #require(pixels)
                        #expect(
                            content.hasContent,
                            Comment(
                                rawValue:
                                    "\(caseName) colors=\(content.colors) contrastEdges=\(content.contrastEdges)"
                            ))
                        let png = try #require(bitmap?.representation(using: .png, properties: [:]))
                        #expect(png.count > 100, Comment(rawValue: caseName))
                        try png.write(
                            to: fixtureDirectory.appendingPathComponent(caseName + ".png"))
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

@MainActor private func musicRenderHasControl(
    _ node: NSObject, label: String, depth: Int = 0
) -> Bool {
    guard depth < 64 else { return false }
    if (node as AnyObject).accessibilityLabel?() == label,
        (node as AnyObject).accessibilityRole?() == NSAccessibility.Role.button
    {
        return true
    }
    for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
        if musicRenderHasControl(child, label: label, depth: depth + 1) { return true }
    }
    if let view = node as? NSView {
        for child in view.subviews {
            if musicRenderHasControl(child, label: label, depth: depth + 1) { return true }
        }
    }
    return false
}

@MainActor private final class MusicReconfigurationTestBridge: NSObject {
    private(set) var requests = 0

    @objc func invoke(_ data: NSData, completion: @escaping (NSData) -> Void) {
        guard
            let request = try? ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data),
            let reply = try? ExtensionEngineWire.encode(
                ExtensionEngineReply(token: request.token, ok: true, payload: Data("{}".utf8)))
        else { return }
        requests += 1
        completion(reply as NSData)
    }

    @objc func cancel(_ token: NSString) {}
}
