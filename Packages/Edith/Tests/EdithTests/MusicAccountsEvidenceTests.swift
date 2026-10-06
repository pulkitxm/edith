import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor @Suite struct MusicAccountsEvidenceTests {
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
        accounts.select(.spotify)
        spotify.receive(
            Data(
                """
                {"event":"connected","account":"sample-listener"}
                {"event":"track","title":"Evening Colors","duration":210}
                {"event":"state","playing":true,"elapsed":42}

                """.utf8), generation: spotify.generation)
        spotify.error = nil
        try await capture(accounts, at: directory.appendingPathComponent("spotify.png"))
        accounts.select(.youtubeMusic)
        try await capture(accounts, at: directory.appendingPathComponent("youtube-music.png"))
        accounts.shutdown()
    }

    private func capture(_ accounts: MusicAccounts, at url: URL) async throws {
        let host = NSHostingView(
            rootView:
                VStack(spacing: 0) {
                    MusicPage(accounts: accounts)
                    MusicFooter(accounts: accounts)
                }
                .environment(\.colorScheme, .dark)
                .frame(width: 1024, height: 640)
                .background(Color(nsColor: .windowBackgroundColor)))
        let window = TestWindowHost.window(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640))
        window.isReleasedWhenClosed = false
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
