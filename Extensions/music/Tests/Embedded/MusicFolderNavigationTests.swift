import AppKit
import EdithExtensionSupport
import EdithExtensionTestSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicFolderNavigationTests {
    private let root = URL(fileURLWithPath: "/tmp/mock-music-library")

    private func entry(_ path: String) -> EmbeddedMusicUIEntry {
        .init(path: path, url: root.appendingPathComponent(path))
    }

    private func state(folders: [String], tracks: [String]) -> EmbeddedMusicUIState {
        EmbeddedMusicUIState(
            root: root, folders: folders.map(entry), folderTracks: tracks.map(entry),
            favourites: [],
            playback: .init(
                path: nil, playing: false, elapsed: 0, duration: 0, volume: 0.5, shuffle: false,
                repeating: false),
            selected: "local",
            spotify: .init(
                connected: false, connecting: false, account: "", title: "", uri: "", artist: "",
                album: "", playing: false, elapsed: 0, duration: 0, volume: 0.7),
            youtubeConnecting: false, youtubeConnected: false, restorePending: 0, events: [],
            cursor: 0, privacy: false)
    }

    private func settle(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready())
    }

    private struct Library {
        var folders: [String: [String]] = [
            "": ["Mock Mix", "Mock Empty"], "Mock Mix": ["Mock Mix/Mock Inner"],
            "Mock Empty": [], "Mock Mix/Mock Inner": [],
        ]
        var tracks: [String: [String]] = [
            "": ["Mock Root.wav"], "Mock Mix": ["Mock Mix/Mock One.wav", "Mock Mix/Mock Two.wav"],
            "Mock Empty": [], "Mock Mix/Mock Inner": ["Mock Mix/Mock Inner/Mock Deep.wav"],
        ]
    }

    private func configure(
        _ remote: EmbeddedMusicRemote, library: Library = Library(),
        prefetched: @escaping ([String]) -> Void = { _ in }
    ) {
        remote.configure { operation, payload in
            switch operation {
            case "music.ui.read":
                let query = try JSONDecoder().decode(EmbeddedMusicUIQuery.self, from: payload)
                return try JSONEncoder().encode(
                    self.state(
                        folders: library.folders[query.path] ?? [],
                        tracks: library.tracks[query.path] ?? []))
            case "music.ui.listings":
                let request = try JSONDecoder().decode(
                    EmbeddedMusicUIListingsRequest.self, from: payload)
                try request.validate()
                prefetched(request.paths)
                var found: [String: EmbeddedMusicUIListing] = [:]
                for path in request.paths {
                    found[path] = EmbeddedMusicUIListing(
                        folders: (library.folders[path] ?? []).map(self.entry),
                        tracks: (library.tracks[path] ?? []).map(self.entry))
                }
                return try JSONEncoder().encode(found)
            case "music.ui.cachedListing":
                return Data("null".utf8)
            default:
                return Data("{}".utf8)
            }
        }
    }

    @Test func navigatingIntoAPrefetchedFolderNeverPresentsASkeleton() async throws {
        let remote = EmbeddedMusicRemote()
        var loadingObserved = false
        configure(remote)
        defer { remote.stop() }
        remote.navigate(to: "")
        try await settle { remote.entriesLoaded }
        try await settle {
            remote.cachedListing("Mock Mix") != nil && remote.cachedListing("Mock Empty") != nil
        }
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if !remote.entriesLoaded { loadingObserved = true }
                await Task.yield()
            }
        }
        defer { observer.cancel() }
        remote.navigate(to: "Mock Mix")
        #expect(remote.entriesLoaded)
        #expect(
            remote.folderTracks.map(\.relativePath) == [
                "Mock Mix/Mock One.wav", "Mock Mix/Mock Two.wav",
            ])
        #expect(remote.listedPath == "Mock Mix")
        try await settle { remote.cachedListing("Mock Mix/Mock Inner") != nil }
        remote.navigate(to: "Mock Mix/Mock Inner")
        #expect(remote.entriesLoaded)
        #expect(
            remote.folderTracks.map(\.relativePath) == ["Mock Mix/Mock Inner/Mock Deep.wav"])
        remote.navigate(to: "")
        #expect(remote.entriesLoaded)
        #expect(remote.folders.map(\.relativePath) == ["Mock Mix", "Mock Empty"])
        try await Task.sleep(for: .milliseconds(40))
        #expect(!loadingObserved)
    }

    @Test func anEmptyFolderGoesStraightToItsEmptyState() async throws {
        let remote = EmbeddedMusicRemote()
        configure(remote)
        defer { remote.stop() }
        remote.navigate(to: "")
        try await settle { remote.cachedListing("Mock Empty") != nil }
        remote.navigate(to: "Mock Empty")
        #expect(remote.entriesLoaded)
        #expect(remote.folders.isEmpty && remote.folderTracks.isEmpty)
        #expect(remote.listedPath == "Mock Empty")
    }

    @Test func anUncachedFolderKeepsThePreviousContentUntilItsListingArrives() async throws {
        let remote = EmbeddedMusicRemote()
        var library = Library()
        library.folders[""] = ["Mock Late"]
        library.tracks["Mock Late"] = ["Mock Late/Mock Song.wav"]
        var held: CheckedContinuation<Void, Never>?
        remote.configure { operation, payload in
            switch operation {
            case "music.ui.read":
                let query = try JSONDecoder().decode(EmbeddedMusicUIQuery.self, from: payload)
                if !query.path.isEmpty { await withCheckedContinuation { held = $0 } }
                return try JSONEncoder().encode(
                    self.state(
                        folders: library.folders[query.path] ?? [],
                        tracks: library.tracks[query.path] ?? []))
            case "music.ui.listings":
                return try JSONEncoder().encode([String: EmbeddedMusicUIListing]())
            case "music.ui.cachedListing":
                return Data("null".utf8)
            default:
                return Data("{}".utf8)
            }
        }
        defer { remote.stop() }
        remote.navigate(to: "")
        try await settle { remote.entriesLoaded }
        remote.navigate(to: "Mock Late")
        #expect(!remote.entriesLoaded)
        #expect(remote.listedPath == "")
        #expect(remote.folders.map(\.relativePath) == ["Mock Late"])
        try await settle { held != nil }
        held?.resume()
        try await settle { remote.entriesLoaded }
        #expect(remote.listedPath == "Mock Late")
        #expect(remote.folderTracks.map(\.relativePath) == ["Mock Late/Mock Song.wav"])
    }

    @Test func libraryChangesDropOtherCachedFolders() async throws {
        let remote = EmbeddedMusicRemote()
        var requests: [[String]] = []
        configure(remote, prefetched: { requests.append($0) })
        defer { remote.stop() }
        remote.navigate(to: "")
        try await settle { remote.cachedListing("Mock Mix") != nil }
        let before = requests.filter { $0.contains("Mock Mix") }.count
        remote.send(.createFolder, path: "", target: "Mock New")
        try await settle { requests.filter { $0.contains("Mock Mix") }.count > before }
        try await settle { remote.cachedListing("Mock Mix") != nil }
        #expect(remote.cachedListing("") != nil)
    }

    @Test func listingRequestsAreBounded() throws {
        let paths = (0...EmbeddedMusicUIListingsRequest.limit).map { "Mock \($0)" }
        #expect(throws: (any Error).self) {
            try EmbeddedMusicUIListingsRequest(paths: paths).validate()
        }
        #expect(throws: (any Error).self) {
            try EmbeddedMusicUIListingsRequest(paths: ["Mock", "Mock"]).validate()
        }
        #expect(throws: (any Error).self) {
            try EmbeddedMusicUIListingsRequest(paths: []).validate()
        }
        try EmbeddedMusicUIListingsRequest(paths: ["Mock A", "Mock B"]).validate()
    }

    @Test func skeletonAndRealGridShareColumnsAndTileFrames() async throws {
        _ = NSApplication.shared
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for zoom in [1.0, 1.6] {
            UIScale.apply(zoom)
            for width in [560.0, 1000.0, 1500.0] {
                let skeleton = await frames(width: width) { probe in
                    EmbeddedMusicTileGrid { layout in
                        ForEach(0..<layout.placeholderCount, id: \.self) { index in
                            EmbeddedMusicTileSkeleton(wide: index.isMultiple(of: 2))
                                .modifier(TileProbe(index: index, probe: probe))
                        }
                    }
                }
                let count = EmbeddedMusicTile.layout(available: width).placeholderCount
                let real = await frames(width: width) { probe in
                    EmbeddedMusicTileGrid { _ in
                        ForEach(0..<count, id: \.self) { index in
                            EmbeddedMusicFolderTile(
                                folder: .init(
                                    url: root.appendingPathComponent("Mock \(index)"),
                                    relativePath: "Mock \(index)"),
                                theme: .teal, location: nil, onOpen: {}, onPlay: {},
                                onDrop: { _ in }, onRename: {}, onDelete: {}
                            )
                            .modifier(TileProbe(index: index, probe: probe))
                        }
                    }
                }
                let label = "zoom \(zoom) width \(width)"
                let expected = EmbeddedMusicTile.layout(available: width).columnCount
                #expect(columns(skeleton) == expected, "\(label)")
                #expect(columns(real) == expected, "\(label)")
                #expect(skeleton.count == real.count, "\(label)")
                for index in 0..<min(skeleton.count, real.count) {
                    let a = try #require(skeleton[index])
                    let b = try #require(real[index])
                    #expect(abs(a.minX - b.minX) < 0.5, "\(label) tile \(index)")
                    #expect(abs(a.minY - b.minY) < 0.5, "\(label) tile \(index)")
                    #expect(abs(a.width - b.width) < 0.5, "\(label) tile \(index)")
                    #expect(abs(a.height - b.height) < 0.5, "\(label) tile \(index)")
                }
            }
        }
    }

    private func columns(_ frames: [Int: CGRect]) -> Int {
        guard let top = frames.values.map(\.minY).min() else { return 0 }
        return frames.values.filter { abs($0.minY - top) < 0.5 }.count
    }

    private func frames<Content: View>(
        width: Double, @ViewBuilder content: (TileFrames) -> Content
    ) async -> [Int: CGRect] {
        let probe = TileFrames()
        let host = NSHostingView(
            rootView: content(probe).coordinateSpace(.named(TileProbe.space))
                .frame(width: width, alignment: .top).fixedSize(horizontal: false, vertical: true)
                .transaction { $0.animation = nil })
        host.frame = CGRect(x: 0, y: 0, width: width, height: 2000)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        window.orderOut(nil)
        window.contentView = nil
        return probe.frames
    }
}

@MainActor private final class TileFrames {
    var frames: [Int: CGRect] = [:]
}

private struct TileProbe: ViewModifier {
    static let space = "music-tile-grid"
    let index: Int
    let probe: TileFrames

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.space))
        } action: { frame in
            MainActor.assumeIsolated { probe.frames[index] = frame }
        }
    }
}
