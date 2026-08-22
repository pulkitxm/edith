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

    @Test func liveLoopbackServerAcceptsHealthAndHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-attention-server-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        let settings = AttentionSettings(
            browserTrackingEnabled: true, serverPort: 0, serverToken: "local-secret")
        let server = AttentionIngestionServer(repository: repository, settings: settings)
        try server.start()
        defer { server.stop() }

        for _ in 0..<100 where server.state == .starting {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.state == .ready)
        let port = try #require(server.boundPort)
        #expect(await AttentionIngestionServer.isHealthy(port: port))

        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/v1/heartbeat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("local-secret", forHTTPHeaderField: "X-Edith-Token")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(sampleHeartbeat())
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)

        let events = repository.events(
            from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        #expect(events.count == 1)
        #expect(events.first?.domain == "music.youtube.com")
        #expect(events.first?.browserProfile == "Default")
    }

    private func sampleHeartbeat() -> AttentionBrowserHeartbeat {
        AttentionBrowserHeartbeat(
            timestamp: now, duration: 15, presence: .active, appName: "Chrome",
            bundleID: "com.google.Chrome",
            url: "https://music.youtube.com/watch?v=secret#fragment", title: "Nights",
            faviconURL: "https://music.youtube.com/favicon.ico", browserProfile: "Default")
    }
}
