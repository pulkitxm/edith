import Foundation
import Testing

@testable import PluginsExtension

@Suite struct SkillDownloadTests {
    @Test(arguments: ["valid", "large-header", "large-stream", "not-found"])
    func boundedDownloadsRejectOversizedHeadersBodiesAndHTTPFailures(mode: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "https://skills.example.test/" + mode))
        if mode == "valid" {
            let data = try await SkillDocumentStore.download(url, session: session)
            #expect(String(decoding: data, as: UTF8.self) == "synthetic document")
        } else {
            await #expect(throws: SkillsError.self) {
                try await SkillDocumentStore.download(url, session: session)
            }
        }
    }

    private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            guard let url = request.url else { return }
            let mode = url.lastPathComponent
            let headers = mode == "large-header" ? ["Content-Length": "400000"] : [:]
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: mode == "not-found" ? 404 : 200,
                    httpVersion: "HTTP/1.1", headerFields: headers)
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data =
                mode == "large-stream"
                ? Data(repeating: 120, count: 400_000)
                : Data("synthetic document".utf8)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
