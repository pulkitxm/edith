import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit

@testable import Edith
@testable import EdithKit

@MainActor @Suite struct MusicAccountsEvidenceTests {
    @Test func reconnectingReplacesTheEmbeddedYouTubePlayer() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let first = WKWebView(frame: .zero, configuration: configuration)
        let second = WKWebView(frame: .zero, configuration: configuration)
        let host = NSHostingView(rootView: MusicYoutubeWebView(view: first))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if first.superview != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(first.superview != nil)
        host.rootView = MusicYoutubeWebView(view: second)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if second.superview != nil, first.superview == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(second.superview != nil)
        #expect(first.superview == nil)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EDITH_MUSIC_EVIDENCE_DIR"] != nil))
    func rendersStreamingSourcesWithSyntheticAccountData() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        let dataRoot = try #require(environment["EDITH_DATA_ROOT"])
        #expect(dataRoot.hasPrefix(runtime + "/"))
        guard dataRoot.hasPrefix(runtime + "/") else { return }
        let directory = URL(fileURLWithPath: try #require(environment["EDITH_MUSIC_EVIDENCE_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "test.music.evidence.\(UUID().uuidString)")!
        let spotify = MusicSpotifySession(executable: nil, defaults: defaults)
        let accounts = MusicAccounts(defaults: defaults, spotify: spotify, pauseLocal: {})
        let originalScale = UIScale.current
        defer { UIScale.apply(originalScale) }
        accounts.select(.spotify)
        spotify.receive(
            Data(
                """
                {"event":"connected","account":"sample-listener"}
                {"event":"track","title":"Evening Colors","artist":"The Daylight Sessions","album":"After Hours","duration":210}
                {"event":"state","playing":true,"elapsed":42}

                """.utf8), generation: spotify.generation)
        spotify.error = nil
        let layouts: [(CGFloat, ColorScheme, Double, String)] = [
            (1024, .dark, 1, ""), (600, .light, 1, "-compact-light"),
            (1024, .light, 1.5, "-zoom-light"), (600, .dark, 1.5, "-compact-zoom"),
        ]
        for provider in [MusicProvider.spotify, .youtubeMusic] {
            accounts.select(provider)
            let name = provider == .spotify ? "spotify" : "youtube-music"
            for (width, scheme, zoom, suffix) in layouts {
                UIScale.apply(zoom)
                try await capture(
                    accounts, width: width, scheme: scheme,
                    at: directory.appendingPathComponent("\(name)\(suffix).png"))
            }
        }
        accounts.select(.spotify)
        for scheme in [ColorScheme.dark, .light] {
            UIScale.apply(1)
            try await captureView(
                HomeMusicCard(dark: scheme == .dark, accounts: accounts).padding(16),
                width: 420, height: 200, scheme: scheme,
                at: directory.appendingPathComponent(
                    "home-music-\(scheme == .dark ? "dark" : "light").png"))
        }
        spotify.stop()
        defaults.removeObject(forKey: "musicSpotifyAccountSaved")
        accounts.select(.spotify)
        spotify.error = nil
        for (width, scheme, zoom, suffix) in layouts {
            UIScale.apply(zoom)
            try await capture(
                accounts, width: width, scheme: scheme,
                at: directory.appendingPathComponent("spotify-connect\(suffix).png"))
        }
        accounts.shutdown()
    }

    private func capture(
        _ accounts: MusicAccounts, width: CGFloat, scheme: ColorScheme, at url: URL
    ) async throws {
        let height = max(640, UIScale.pt(540))
        try await captureView(
            VStack(spacing: 0) {
                MusicPage(accounts: accounts)
                MusicFooter(accounts: accounts)
            }, width: width, height: height, scheme: scheme, at: url)
    }

    private func captureView<Content: View>(
        _ content: Content, width: CGFloat, height: CGFloat, scheme: ColorScheme, at url: URL
    ) async throws {
        let host = NSHostingView(
            rootView:
                content
                .environment(\.colorScheme, scheme)
                .environment(\.compactLayout, width < 900)
                .environment(\.automaticViewActionsEnabled, false)
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor)))
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height))
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(100)) }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(image.count > 10_000)
        try image.write(to: url)
    }
}
