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

    @Test func originalEmbeddedControllersRenderAtBothWidthsThemesAndZoom() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let remote = EmbeddedMusicRemote.shared
        let encoded = try JSONEncoder().encode(state())
        remote.configure { _, _ in encoded }
        remote.rescan()
        for _ in 0..<20 where !remote.entriesLoaded { await Task.yield() }
        defer { remote.stop(); UIScale.apply(1) }
        for width in [540.0, 960.0] {
            for scheme in [ColorScheme.light, .dark] {
                for zoom in [1.0, 1.5] {
                    UIScale.apply(zoom)
                    for route in EmbeddedMusicSceneRoute.allCases {
                        let state = ExtensionPresentationState(
                            compact: width < 720, visible: false, availableWidth: width,
                            intrinsic: route != .page)
                        let controller = try #require(
                            state.withContext {
                                EmbeddedMusicAuxiliaryScenes.controller([
                                    "location": route.rawValue, "section": "music",
                                ])
                            })
                        controller.view.frame = CGRect(
                            x: 0, y: 0, width: width, height: route == .page ? 800 : 200)
                        controller.view.appearance = NSAppearance(
                            named: scheme == .dark ? .darkAqua : .aqua)
                        let window = NSWindow(
                            contentRect: controller.view.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
                        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                        window.contentViewController = controller
                        window.orderBack(nil)
                        controller.view.layoutSubtreeIfNeeded()
                        let bitmap = try #require(
                            controller.view.bitmapImageRepForCachingDisplay(
                                in: controller.view.bounds))
                        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        #expect(png.count > 100)
                        #expect(window.frame.maxX < 0)
                        window.orderOut(nil); window.contentViewController = nil
                        #expect(controller.view.fittingSize.width.isFinite)
                        #expect(controller.view.fittingSize.height.isFinite)
                    }
                }
            }
        }
    }
}
