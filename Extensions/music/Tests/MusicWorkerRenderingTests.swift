import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @MainActor @Suite struct MusicWorkerRenderingTests {
        @Test func completeScreensRenderOffscreenAtCompactRegularAndIncreasedZoom() async throws {
            let root = URL(fileURLWithPath: "/tmp/music-preview-library-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let defaults = SharedDefaults.store
            let prior = defaults.string(forKey: MusicStorage.musicFolderPathKey)
            let priorScale = UIScale.current
            defer {
                defaults.set(prior, forKey: MusicStorage.musicFolderPathKey)
                UIScale.apply(priorScale); TrackMeta.invalidateCaches(); MusicRemote.shared.stop()
            }
            MusicStorage.setMusicDirectory(root)
            TrackMeta.invalidateCaches()
            for name in ["Mock Garden.m4a", "Mock Waves.mp3"] {
                try Data().write(to: root.appendingPathComponent(name))
            }
            let id = "test.music.render." + UUID().uuidString
            let accountDefaults = try #require(UserDefaults(suiteName: id))
            defer { accountDefaults.removePersistentDomain(forName: id) }
            let accounts = MusicAccounts(
                defaults: accountDefaults,
                spotify: MusicSpotifySession(libraryURL: nil, defaults: accountDefaults),
                pauseLocal: {})
            defer { accounts.shutdown() }
            let downloader = YoutubeDownloader(start: false)
            defer { downloader.shutdown() }
            downloader.apply(
                .init(
                    records: [
                        .init(
                            id: UUID(), url: URL(string: "https://example.com/mock-track")!,
                            status: .done("Mock Garden.m4a"), outputFilename: "Mock Garden.m4a",
                            createdAt: .now, kind: .audio),
                        .init(
                            id: UUID(), url: URL(string: "https://example.com/mock-video")!,
                            status: .interrupted("Stopped before an update"),
                            outputFilename: "Mock Video.mp4", createdAt: .now, kind: .video),
                    ], logs: [:], enabled: true, running: false, generation: UUID(), revision: 1,
                    executable: URL(fileURLWithPath: "/tmp/mock-tools/yt-dlp")))
            MusicRemote.shared.start()
            for section in MusicRootView.Section.allCases {
                for (name, width, zoom) in [
                    ("compact", 540.0, 1.0), ("regular", 960.0, 1.0), ("zoomed", 960.0, 1.5),
                ] {
                    for scheme in [ColorScheme.light, .dark] {
                        UIScale.apply(zoom)
                        let host = NSHostingView(
                            rootView: NavigationRouteHost(router: WindowRouter()) {
                                MusicRootView(
                                    initialSection: section, accounts: accounts,
                                    downloader: downloader)
                            }
                            .environment(\.compactLayout, width < 720)
                            .environment(\.automaticViewActionsEnabled, false)
                            .preferredColorScheme(scheme)
                            .transaction { $0.animation = nil })
                        host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                        let window = TestWindowHost.window(contentRect: host.frame)
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        host.appearance = window.appearance
                        window.contentView = host; window.orderBack(nil)
                        for _ in 0..<8 {
                            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded();
                            window.displayIfNeeded(); host.display()
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        #expect(abs(host.bounds.width - width) < 1)
                        #expect(!TestWindowHost.isExposedOnDesktop(window))
                        try capture(
                            host,
                            name: "music-" + section.rawValue.lowercased() + "-" + name + "-"
                                + (scheme == .dark ? "dark" : "light"))
                        window.orderOut(nil)
                    }
                }
            }
        }

        private func capture(_ host: NSView, name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_MUSIC"]
            else { return }
            let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: representation)
            let data = try #require(representation.representation(using: .png, properties: [:]))
            #expect(data.count > 2000)
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(name + ".png"))
        }
    }
}
