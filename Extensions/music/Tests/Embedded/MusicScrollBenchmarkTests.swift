import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicEmbeddedUI

@MainActor @Suite(.serialized) struct MusicScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil
    static let medianBudget = ProcessInfo.processInfo.environment["CI"] == nil ? 12.0 : 1000.0 / 60

    @Test(.enabled(if: enabled)) func scrollingTracksAndFavouritesWithSyntheticLibrary()
        async throws
    {
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        for favourites in [false, true] {
            for pace in MusicScrollPace.allCases
            where only == nil
                || only == "\(favourites ? "favourites" : "tracks")-\(pace.rawValue)"
            {
                let timing = try await MusicSyntheticLibrary.measure(
                    tracks: 5000, favourites: 1000, showingFavourites: favourites, frames: frames,
                    pace: pace)
                print(
                    "music-scroll \(favourites ? "favourites-1000" : "tracks-5000") \(pace.rawValue): \(timing)"
                )
            }
        }
    }

    @Test func scrollingStaysSmoothWithSmallLibrary() async throws {
        let timing = try await MusicSyntheticLibrary.measure(
            tracks: 600, favourites: 200, showingFavourites: false, frames: 60)
        #expect(timing.worst < 80)
        #expect(timing.median < Self.medianBudget)
    }
}

enum MusicScrollPace: String, CaseIterable {
    case steady, fling, sweep

    @MainActor func step(documentHeight: CGFloat, frames: Int) -> CGFloat {
        switch self {
        case .steady: 24
        case .fling: 100
        case .sweep: max(24, documentHeight / CGFloat(frames))
        }
    }
}

@MainActor
enum MusicSyntheticLibrary {
    static let root = URL(fileURLWithPath: "/tmp/mock-music-library")

    static func entry(_ index: Int) -> EmbeddedMusicUIEntry {
        let path = "Mock Album \(index / 40)/Mock Track Number \(index).m4a"
        return .init(path: path, url: root.appendingPathComponent(path))
    }

    static func state(tracks: Int, favourites: Int) -> EmbeddedMusicUIState {
        EmbeddedMusicUIState(
            root: root, folders: [], folderTracks: (0..<tracks).map(entry),
            favourites: (0..<favourites).map { entry($0 * 5) },
            playback: .init(
                path: entry(3).path, playing: true, elapsed: 12, duration: 100, volume: 0.5,
                shuffle: false, repeating: false),
            selected: "local",
            spotify: .init(
                connected: false, connecting: false, account: "", title: "", uri: "", artist: "",
                album: "", playing: false, elapsed: 0, duration: 0, volume: 0.7),
            youtubeConnecting: false, youtubeConnected: false, restorePending: 0, events: [],
            cursor: 0, privacy: false)
    }

    static let artwork: Data = {
        let side = 256
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGradient(colors: [.systemPink, .systemIndigo])?.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side), angle: 45)
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }()

    static func measure(
        tracks: Int, favourites: Int, showingFavourites: Bool, frames: Int,
        pace: MusicScrollPace = .steady
    ) async throws -> MusicScrollTiming {
        let remote = EmbeddedMusicRemote.shared
        let encoded = try JSONEncoder().encode(state(tracks: tracks, favourites: favourites))
        let artwork = try JSONEncoder().encode(artwork)
        let duration = try JSONEncoder().encode("3:42")
        remote.configure { operation, _ in
            switch operation {
            case "music.ui.read": return encoded
            case "music.ui.artwork":
                try await Task.sleep(for: .milliseconds(2))
                return artwork
            case "music.ui.duration":
                try await Task.sleep(for: .milliseconds(1))
                return duration
            default: return Data("{}".utf8)
            }
        }
        defer {
            remote.stop()
            EmbeddedTrackMeta.clear()
        }
        remote.rescan()
        for _ in 0..<400 where !remote.entriesLoaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        if showingFavourites { remote.openFavourites() }
        let (window, host) = MusicScrollHarness.host(
            EmbeddedMusicPage()
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1280, height: 860))
        await MusicScrollHarness.settle(host, for: .seconds(1))
        let height = MusicScrollHarness.scrollView(in: host)?.documentView?.frame.height ?? 0
        let step = pace.step(documentHeight: height, frames: frames)
        let timing = await MusicScrollHarness.scroll(host, step: step, frames: frames)
        await MusicScrollHarness.settle(host)
        window.orderOut(nil)
        window.contentView = nil
        return timing
    }
}
