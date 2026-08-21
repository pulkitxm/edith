import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionIngestionTests {
    let now = Date(timeIntervalSince1970: 1_775_000_000)

    @Test func requestParserWaitsForCompleteBody() throws {
        let body = Data("{\"ok\":true}".utf8)
        let header = Data(
            "POST /v1/heartbeat HTTP/1.1\r\nContent-Length: \(body.count)\r\nX-Edith-Token: secret\r\n\r\n"
                .utf8)
        #expect(AttentionHTTPRequest.parse(header + body.prefix(3)) == nil)
        let request = try #require(AttentionHTTPRequest.parse(header + body))
        #expect(request.method == "POST")
        #expect(request.path == "/v1/heartbeat")
        #expect(request.headers["x-edith-token"] == "secret")
        #expect(request.body == body)
    }

    @Test func domainModeStripsPathTitleAndQuery() {
        let heartbeat = sampleHeartbeat()
        let event = AttentionIngestionServer.browserEvent(from: heartbeat, privacyLevel: .domains)
        #expect(event.domain == "music.youtube.com")
        #expect(event.url == nil)
        #expect(event.windowTitle == nil)
        #expect(event.faviconURL == heartbeat.faviconURL)
    }

    @Test func detailedModeKeepsSanitizedPathAndTitle() {
        let heartbeat = sampleHeartbeat()
        let event = AttentionIngestionServer.browserEvent(from: heartbeat, privacyLevel: .detailed)
        #expect(event.url == "https://music.youtube.com/watch")
        #expect(event.windowTitle == "Nights")
        #expect(event.domain == "music.youtube.com")
    }

    @Test func applicationsModeDropsAllPageIdentity() {
        let heartbeat = sampleHeartbeat()
        let event = AttentionIngestionServer.browserEvent(
            from: heartbeat, privacyLevel: .applications)
        #expect(event.url == nil)
        #expect(event.domain == nil)
        #expect(event.windowTitle == nil)
        #expect(event.faviconURL == nil)
        #expect(event.appName == "Chrome")
    }

    @Test func responseHasCORSAndExactLength() throws {
        let response = AttentionHTTPResponse(status: 202, body: ["status": "accepted"])
        let text = try #require(String(data: response.data, encoding: .utf8))
        #expect(text.contains("Access-Control-Allow-Origin: *"))
        #expect(text.contains("HTTP/1.1 202 Accepted"))
        let parts = text.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        #expect(text.contains("Content-Length: \(Data(parts[1].utf8).count)"))
    }

    private func sampleHeartbeat() -> AttentionBrowserHeartbeat {
        AttentionBrowserHeartbeat(
            timestamp: now, duration: 15, presence: .active, appName: "Chrome",
            bundleID: "com.google.Chrome",
            url: "https://music.youtube.com/watch?v=secret#fragment", title: "Nights",
            faviconURL: "https://music.youtube.com/favicon.ico", browserProfile: "Default")
    }
}
