import Foundation
import Testing
@testable import SEOAuditExtension

@Suite(.serialized) struct SEOAuditHTTPClientTests {
    @Test func boundsDeclaredAndStreamedResponsesBeforeParsing() async throws {
        let client = makeClient()
        defer { client.shutdown() }
        let (data, response) = try await client.data(for: request("small"), maximumBytes: 16)
        #expect(data.count == 8)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        for path in ["declared", "stream"] {
            await #expect(throws: (any Error).self) {
                _ = try await client.data(for: request(path), maximumBytes: 16)
            }
        }
    }

    @Test func cancellationStopsOwnedRequestsAndShutdownRejectsNewWork() async throws {
        SEOAuditHTTPProtocol.reset()
        let client = makeClient()
        let task = Task { try await client.data(for: request("wait"), maximumBytes: 16) }
        for _ in 0..<100 {
            if SEOAuditHTTPProtocol.started > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(SEOAuditHTTPProtocol.started == 1)
        task.cancel()
        _ = try? await task.value
        for _ in 0..<100 {
            if SEOAuditHTTPProtocol.stopped > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(SEOAuditHTTPProtocol.stopped > 0)
        client.shutdown()
        await #expect(throws: (any Error).self) {
            _ = try await client.data(for: request("small"), maximumBytes: 16)
        }
    }

    @Test func rejectsFileAndCredentialBearingURLs() async throws {
        let client = makeClient()
        defer { client.shutdown() }
        for text in [
            "file:///tmp/page.html", "https://mock:secret@example.invalid/",
            "ftp://example.invalid/page",
        ] {
            let url = try #require(URL(string: text))
            await #expect(throws: SEOAuditInputError.self) {
                _ = try await client.data(for: URLRequest(url: url), maximumBytes: 16)
            }
        }
    }

    private func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://synthetic.example.invalid/" + path)!)
    }
    private func makeClient() -> SEOAuditHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SEOAuditHTTPProtocol.self]
        return SEOAuditHTTPClient(configuration: configuration)
    }
}

private final class SEOAuditHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var starts = 0
    private static var stops = 0
    static var started: Int { lock.withLock { starts } }
    static var stopped: Int { lock.withLock { stops } }
    static func reset() {
        lock.withLock {
            starts = 0; stops = 0
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.starts += 1 }
        if request.url?.lastPathComponent == "wait" { return }
        let declared = request.url?.lastPathComponent == "declared"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: [
                "Content-Type": "text/plain", "Content-Length": declared ? "1000" : "-1",
            ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunks = request.url?.lastPathComponent == "stream" ? 3 : 1
        for _ in 0..<chunks { client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.stops += 1 } }
}
