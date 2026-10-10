import EdithExtensionSupport
import Foundation
import Testing
import WebKit

@testable import MusicEmbeddedUI
@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicNativeBrowserTests {
    private func cookie(domain: String = ".youtube.com") throws -> HTTPCookie {
        try #require(
            HTTPCookie(properties: [
                .name: "SID", .value: "mock-music-session", .domain: domain, .path: "/",
                .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            ]))
    }

    @Test func originalNativeBrowserHasOfflineInteractionAndDrainsItsEphemeralSession() async throws
    {
        let values = [try cookie(), try cookie(domain: ".example.com")]
        let engine = MusicBrowserPresentation(connected: { true }, cookies: { values })
        let engineLease = try await engine.open()
        let lease = try JSONDecoder().decode(
            EmbeddedMusicBrowserLease.self, from: JSONEncoder().encode(engineLease))
        #expect(lease.cookies.count == 1)
        let session = try EmbeddedMusicBrowserSession(lease: lease) { operation, payload in
            switch operation {
            case "music.ui.youtube.sync":
                return try JSONEncoder().encode(
                    engine.sync(JSONDecoder().decode(MusicBrowserReport.self, from: payload)))
            case "music.ui.youtube.close":
                try engine.close(JSONDecoder().decode(MusicBrowserToken.self, from: payload));
                return Data("{}".utf8)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
        defer { session.stop(); engine.stop() }
        try await session.start(loadHome: false)
        #expect(!session.store.isPersistent)
        #expect(session.webView.window == nil)
        #expect(session.webView.configuration.mediaTypesRequiringUserActionForPlayback == .all)
        let cookies = await session.store.httpCookieStore.allCookies()
        #expect(cookies.map(\.value) == ["mock-music-session"])
        #expect(cookies.first?.isSecure == true)
        #expect(cookies.first?.isHTTPOnly == true)
        session.webView.loadHTMLString(
            """
            <!doctype html><html><body><button id="mock-control" onclick="document.getElementById('mock-result').textContent='selected'">Mock track</button><p id="mock-result">ready</p></body></html>
            """, baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            ready =
                (try? await session.webView.evaluateJavaScript(
                    "document.getElementById('mock-result')?.textContent")) as? String == "ready"
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready)
        let result = try await session.webView.evaluateJavaScript(
            "document.getElementById('mock-control').click(); document.getElementById('mock-result').textContent"
        )
        #expect(result as? String == "selected")
        try await session.synchronize()
        #expect(engine.metadata?.title == "YouTube Music")
        session.webViewWebContentProcessDidTerminate(session.webView)
        #expect(session.error == "YouTube Music stopped. Reload to reconnect.")
        session.stop()
        await EmbeddedMusicBrowserSession.drainAll()
        #expect(session.stopped)
        #expect(session.webView.navigationDelegate == nil)
        #expect(session.webView.uiDelegate == nil)
        #expect(!session.webView.isLoading)
        #expect(session.webView.window == nil)
        #expect(await session.store.httpCookieStore.allCookies().isEmpty)
        #expect(engine.metadata == nil)
        #expect(throws: (any Error).self) {
            try engine.validate(.init(id: lease.id, revision: lease.revision))
        }
        await #expect(throws: CancellationError.self) { try await session.start(loadHome: false) }
    }

    @Test func checkedCookieAndNavigationCapabilitiesRejectForeignOrExpiredData() throws {
        let cookie = EmbeddedMusicBrowserCookie(
            name: "SID", value: "mock", domain: ".youtube.com", path: "/", secure: true,
            httpOnly: true)
        let lease = EmbeddedMusicBrowserLease(id: UUID(), revision: UUID(), cookies: [cookie])
        try lease.validate()
        for invalid in [
            EmbeddedMusicBrowserCookie(
                name: "SID", value: "mock", domain: ".youtube.com.evil.example", path: "/",
                secure: true, httpOnly: true),
            EmbeddedMusicBrowserCookie(
                name: "SID", value: "mock\0data", domain: ".youtube.com", path: "/", secure: true,
                httpOnly: true),
            EmbeddedMusicBrowserCookie(
                name: "SID", value: "mock", domain: ".youtube.com", path: "/", secure: true,
                httpOnly: true, expires: 1),
        ] { #expect(throws: (any Error).self) { try invalid.validate() } }
        #expect(throws: (any Error).self) {
            try EmbeddedMusicBrowserLease(
                id: UUID(), revision: UUID(), cookies: Array(repeating: cookie, count: 257)
            ).validate()
        }
        for value in [
            "https://music.youtube.com/", "https://www.youtube.com/watch?v=mock",
            "https://consent.youtube.com/",
        ] {
            #expect(EmbeddedMusicBrowserSession.isYoutubePage(URL(string: value)!))
        }
        for value in [
            "file:///tmp/Mock", "http://music.youtube.com/",
            "https://music.youtube.com.evil.example/", "https://mock@music.youtube.com/",
            "https://music.youtube.com:444/",
        ] {
            #expect(!EmbeddedMusicBrowserSession.isYoutubePage(URL(string: value)!))
        }
        #expect(!EmbeddedMusicBrowserSession.isExternal(URL(string: "javascript:alert('mock')")!))
    }

    @Test func engineRevocationRejectsLateCookieHandoffsAndStaleFixedControls() async throws {
        let value = try cookie()
        var pending: CheckedContinuation<[HTTPCookie], Error>?
        let engine = MusicBrowserPresentation(
            connected: { true },
            cookies: {
                try await withCheckedThrowingContinuation { pending = $0 }
            })
        let open = Task { try await engine.open() }
        for _ in 0..<50 where pending == nil { await Task.yield() }
        #expect(pending != nil)
        engine.revoke()
        pending?.resume(returning: [value])
        await #expect(throws: CancellationError.self) { try await open.value }
        #expect(engine.metadata == nil)
        let connected = MusicBrowserPresentation(connected: { true }, cookies: { [value] })
        defer { connected.stop() }
        let lease = try await connected.open()
        let token = MusicBrowserToken(id: lease.id, revision: lease.revision)
        try connected.send("volume", value: 0.25)
        let report = MusicBrowserReport(
            token: token, cursor: 0, title: "Mock Garden", artist: "Mock Artist", key: "mock-track",
            playing: false, elapsed: 0, duration: 90, volume: 0.7)
        let reply = try connected.sync(report)
        #expect(reply.commands.count == 1)
        #expect(reply.commands.first?.action == "volume")
        #expect(reply.commands.first?.value == 0.25)
        var acknowledged = report; acknowledged.cursor = 1
        #expect(try connected.sync(acknowledged).commands.isEmpty)
        #expect(throws: (any Error).self) { try connected.send("evaluateJavaScript") }
        #expect(throws: (any Error).self) { try connected.send("seek", value: 2) }
        #expect(throws: (any Error).self) {
            try connected.validate(.init(id: UUID(), revision: lease.revision))
        }
        connected.stop()
        #expect(throws: (any Error).self) { try connected.sync(report) }
    }
}
