import Foundation
import Testing
import WebKit

@testable import Edith
@testable import EdithKit

@Suite struct MusicProviderTests {
    @Test(arguments: ["track", "album", "playlist", "episode"])
    func acceptsUrisAndOfficialLinks(_ kind: String) {
        let id = "0123456789abcdefghijkl"
        let uri = "spotify:\(kind):\(id)"
        #expect(MusicProvider.spotifyURI(uri) == uri)
        #expect(
            MusicProvider.spotifyURI(" https://open.spotify.com/\(kind)/\(id)?si=mock \n") == uri)
        #expect(MusicProvider.spotifyURI("https://open.spotify.com/intl-en/\(kind)/\(id)") == uri)
    }

    @Test(arguments: [
        "spotify:track:short", "spotify:artist:0123456789abcdefghijkl",
        "spotify:track:0123456789abcdefghijk!", "spotify:track:0123456789abcdefghijké",
        "https://open.spotify.com.evil.example/track/0123456789abcdefghijkl",
        "http://open.spotify.com/track/0123456789abcdefghijkl",
        "https://evil.example/track/0123456789abcdefghijkl",
        "https://open.spotify.com/track/0123456789abcdefghijkl/extra",
        "https://user@open.spotify.com/track/0123456789abcdefghijkl",
        "https://open.spotify.com:443/track/0123456789abcdefghijkl",
        "spotify:track:0123456789abcdefghijkl:extra", "",
    ])
    func rejectsInvalidLinks(_ value: String) {
        #expect(MusicProvider.spotifyURI(value) == nil)
    }

    @Test func providersHaveStableDistinctIdentities() {
        #expect(MusicProvider.allCases.map(\.id) == ["local", "spotify", "youtubeMusic"])
        #expect(MusicProvider.local.homeURL == nil)
        #expect(MusicBrowserConnection.youtubeHosts.contains(".youtube.com"))
        #expect(!MusicBrowserConnection.youtubeHosts.contains(".google.com"))
        #expect(!MusicBrowserConnection.youtubeHosts.contains(".example.com"))
    }
}

@MainActor @Suite struct MusicSpotifySessionTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test.music.accounts.\(UUID().uuidString)")!
    }

    private func event(_ text: String, to session: MusicSpotifySession) {
        session.receive(Data((text + "\n").utf8), generation: session.generation)
    }

    @Test func framesPartialLinesAndIgnoresMalformedEvents() {
        let store = defaults()
        let session = MusicSpotifySession(executable: nil, defaults: store)
        session.receive(Data("{\"event\":\"con".utf8), generation: 0)
        #expect(!session.connected)
        session.receive(
            Data(
                "nected\",\"account\":\"mock-listener\"}\ninvalid json\n{\"event\":\"track\",\"title\":\"Sample Song\",\"duration\":180}\n"
                    .utf8), generation: 0)
        #expect(session.connected)
        #expect(session.account == "mock-listener")
        #expect(session.title == "Sample Song")
        #expect(session.duration == 180)
        #expect(store.bool(forKey: "musicSpotifyAccountSaved"))
    }

    @Test func cancellationDiscardsLateResponses() {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        let old = session.generation
        session.stop()
        session.receive(
            Data("{\"event\":\"connected\",\"account\":\"old-account\"}\n".utf8), generation: old)
        #expect(!session.connected)
        #expect(session.account.isEmpty)
        #expect(session.generation != old)
    }

    @Test func trackMetadataUpdatesAndClearsBetweenTracks() {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        event(
            #"{"event":"track","title":"Mock Track","artist":"Mock Artist","album":"Mock Album","artwork":"https://i.scdn.co/image/mock-cover","duration":180}"#,
            to: session)
        #expect(session.artist == "Mock Artist")
        #expect(session.album == "Mock Album")
        #expect(session.artworkURL?.absoluteString == "https://i.scdn.co/image/mock-cover")
        event(#"{"event":"track","title":"Another Mock Track","duration":90}"#, to: session)
        #expect(session.artist.isEmpty)
        #expect(session.album.isEmpty)
        #expect(session.artworkURL == nil)
        session.stop()
        #expect(session.title.isEmpty)
    }

    @Test(arguments: [
        "http://i.scdn.co/image/mock", "https://evil.example/image/mock",
        "https://i.scdn.co.evil.example/image/mock", "https://user@i.scdn.co/image/mock",
        "https://i.scdn.co:8443/image/mock", "file:///tmp/mock-cover.png",
        "https://i.scdn.co/unrelated/mock",
    ])
    func rejectsUntrustedArtworkLocations(_ artwork: String) throws {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        let event = try JSONSerialization.data(withJSONObject: [
            "event": "track", "artwork": artwork,
        ])
        session.receive(event + Data([10]), generation: session.generation)
        #expect(session.artworkURL == nil)
    }

    @Test func errorsAreVisibleAndPlaybackResetsAfterExit() {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        event(#"{"event":"connected","account":"mock-listener"}"#, to: session)
        event(#"{"event":"track","title":"Sample Song","duration":120}"#, to: session)
        event(#"{"event":"state","playing":true,"elapsed":10}"#, to: session)
        event(#"{"event":"error","message":"Premium is required."}"#, to: session)
        #expect(session.playing)
        #expect(session.elapsed >= 10)
        session.terminated(generation: session.generation)
        #expect(!session.connected)
        #expect(!session.playing)
        #expect(session.title.isEmpty)
        #expect(session.error == "Premium is required.")
        #expect(session.hasSavedAccount)
    }

    @Test func invalidOrUnboundedResponsesDoNotCorruptPlayback() {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        event(#"{"event":"track","duration":-10}"#, to: session)
        event(#"{"event":"volume","value":5}"#, to: session)
        #expect(session.duration == 0)
        #expect(session.volume == 1)
        session.setVolume(.nan)
        #expect(session.volume == 1)
        session.receive(Data(repeating: 65, count: 65_537), generation: session.generation)
        #expect(session.error != nil)
        #expect(!session.connected)
    }

    @Test func missingEngineAndInvalidLinkGiveActionableErrors() {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        session.connect(authorize: false)
        #expect(session.error == nil)
        session.connect()
        #expect(session.error?.contains("missing") == true)
        #expect(!session.connecting)
        session.play("https://example.com")
        #expect(session.error?.contains("Spotify") == true)
    }

    @Test func seeksClampAndPositionUpdatesKeepThePlaybackState() {
        let session = MusicSpotifySession(executable: nil, defaults: defaults())
        event(#"{"event":"track","title":"Sample Song","duration":120}"#, to: session)
        event(#"{"event":"state","playing":false,"elapsed":10}"#, to: session)
        session.seek(by: -50)
        #expect(session.elapsed == 0)
        session.seek(by: 500)
        #expect(session.elapsed == 120)
        session.seek(by: .nan)
        #expect(session.elapsed == 120)
        event(#"{"event":"position","elapsed":45}"#, to: session)
        #expect(session.elapsed == 45)
        #expect(!session.playing)
    }

    @Test func processExchangesRealPipeCommandsAndDisconnects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mock-player")
        let commands = root.appendingPathComponent("commands.jsonl")
        let body = """
            #!/bin/sh
            if [ "$3" = "--forget" ]; then exit 0; fi
            printf '%s\\n' '{"event":"connected","account":"mock-listener"}'
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> "$1"
            done
            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let store = defaults()
        let session = MusicSpotifySession(
            executable: script, defaults: store, service: commands.path)
        defer { session.stop() }
        session.connect()
        for _ in 0..<500 {
            if session.connected { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            session.connected, Comment(rawValue: session.error ?? "Mock player timed out."))
        session.play("https://open.spotify.com/track/0123456789abcdefghijkl")
        for _ in 0..<500 {
            if (try? String(contentsOf: commands, encoding: .utf8).contains("spotify:track:"))
                == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let recorded = try String(contentsOf: commands, encoding: .utf8)
        #expect(recorded.contains("spotify:track:0123456789abcdefghijkl"))
        await session.disconnect()
        #expect(!session.connected)
        #expect(!store.bool(forKey: "musicSpotifyAccountSaved"))
        #expect(!session.hasSavedAccount)
        #expect(!session.disconnecting)
    }

    @Test func exitedPlayerRejectsWritesWithoutBreakingTheApp() async throws {
        let process = try MusicPlaybackProcess(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"],
            receive: { _ in }, onExit: {})
        await process.waitForExit()
        let failed = DispatchSemaphore(value: 0)
        process.send(Data([10])) { failed.signal() }
        let rejected = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: failed.wait(timeout: .now() + 2) == .success)
            }
        }
        #expect(rejected)
    }
}

@MainActor @Suite struct MusicBrowserConnectionTests {
    @Test func onlyReadsYouTubeHostsFromSyntheticChrome() throws {
        let chrome = try SyntheticChrome(profiles: [
            SyntheticChromeProfile(
                directory: "Default", name: "Mock Music",
                cookies: [
                    SyntheticChromeCookie(
                        host: ".youtube.com", name: "SID", value: "mock-youtube-session"),
                    SyntheticChromeCookie(
                        host: ".google.com", name: "SID", value: "mock-google-session"),
                    SyntheticChromeCookie(
                        host: ".example.com", name: "SID", value: "mock-unrelated-session"),
                    SyntheticChromeCookie(
                        host: ".youtube.com.evil.example", name: "SID",
                        value: "mock-spoofed-session"),
                ])
        ])
        defer { chrome.remove() }
        let cookies = try ChromeCookieReader.read(
            database: chrome.root.appendingPathComponent("Default/Cookies"),
            key: SyntheticChrome.key, allowedHosts: MusicBrowserConnection.youtubeHosts)
        #expect(cookies.map(\.value) == ["mock-youtube-session"])
        let empty = try ChromeCookieReader.read(
            database: chrome.root.appendingPathComponent("Default/Cookies"),
            key: SyntheticChrome.key, allowedHosts: [])
        #expect(empty.isEmpty)
    }

    @Test func importingReplacesOnlyTheDedicatedSessionAndRejectsUnrelatedCookies() async throws {
        let music = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        let unrelated = try #require(
            HTTPCookie(properties: [
                .domain: ".example.com", .path: "/", .name: "SID", .value: "mock-other",
            ]))
        let youtube = try #require(
            HTTPCookie(properties: [
                .domain: ".youtube.com", .path: "/", .name: "SID", .value: "mock-music",
            ]))
        await other.httpCookieStore.setCookie(unrelated)
        await music.httpCookieStore.setCookie(unrelated)
        try await MusicBrowserConnection.apply([youtube, unrelated], to: music)
        #expect(await music.httpCookieStore.allCookies().map(\.value) == ["mock-music"])
        #expect(await other.httpCookieStore.allCookies().map(\.value) == ["mock-other"])
        await #expect(throws: MusicConnectionError.self) {
            try await MusicBrowserConnection.apply([unrelated], to: music)
        }
        #expect(await music.httpCookieStore.allCookies().map(\.value) == ["mock-music"])
    }
}

@MainActor @Suite struct MusicAccountSelectionTests {
    @Test func switchingPausesLocalPlaybackAndPersistsSource() {
        let defaults = UserDefaults(suiteName: "test.music.selection.\(UUID().uuidString)")!
        var pauses = 0
        let spotify = MusicSpotifySession(executable: nil, defaults: defaults)
        let accounts = MusicAccounts(
            defaults: defaults, spotify: spotify, pauseLocal: { pauses += 1 })
        accounts.select(.local)
        #expect(pauses == 0)
        #expect(accounts.playerReady)
        accounts.select(.spotify)
        #expect(!accounts.playerReady)
        spotify.receive(
            Data("{\"event\":\"connected\",\"account\":\"mock-listener\"}\n".utf8),
            generation: spotify.generation)
        #expect(accounts.playerReady)
        #expect(pauses == 1)
        #expect(defaults.string(forKey: "musicSelectedProvider") == "spotify")
        accounts.select(.youtubeMusic)
        #expect(pauses == 1)
        #expect(accounts.selected == .youtubeMusic)
        #expect(!accounts.youtubeConnected)
        #expect(accounts.youtubeView == nil)
        #expect(!accounts.playerReady)
        accounts.select(.local)
        #expect(accounts.selected == .local)
        #expect(accounts.playerReady)
    }

    @Test func restoresKnownSourcesAndFallsBackForUnknownValues() {
        let defaults = UserDefaults(suiteName: "test.music.restore.\(UUID().uuidString)")!
        defaults.set("youtubeMusic", forKey: "musicSelectedProvider")
        let spotify = MusicSpotifySession(executable: nil, defaults: defaults)
        #expect(
            MusicAccounts(defaults: defaults, spotify: spotify, pauseLocal: {}).selected
                == .youtubeMusic)
        defaults.set("unknown", forKey: "musicSelectedProvider")
        #expect(
            MusicAccounts(defaults: defaults, spotify: spotify, pauseLocal: {}).selected == .local)
    }

    @Test(arguments: [
        "https://music.youtube.com/", "https://www.youtube.com/watch?v=mock",
        "https://consent.youtube.com/",
    ])
    func allowsYoutubePlayerPages(_ value: String) {
        #expect(MusicAccounts.isYoutubePage(URL(string: value)!))
    }

    @Test(arguments: [
        "http://music.youtube.com/", "https://music.youtube.com.evil.example/",
        "https://accounts.google.com/", "file:///tmp/mock.html",
    ])
    func rejectsEmbeddedSignInAndUnrelatedNavigation(_ value: String) {
        #expect(!MusicAccounts.isYoutubePage(URL(string: value)!))
    }
}
