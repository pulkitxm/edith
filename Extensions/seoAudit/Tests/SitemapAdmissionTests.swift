import Foundation
import Testing
@testable import SEOAuditExtension

@Suite struct SitemapAdmissionTests {
    @Test func malformedLocationsCannotScheduleLocalFileOrCredentialRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SitemapAdmissionProtocol.self]
        let network = SEOAuditHTTPClient(configuration: configuration)
        defer { network.shutdown() }
        let crawler = SitemapCrawler(session: network, maximumPages: 2)
        let urls = try await crawler.pages(
            startingAt: URL(string: "https://synthetic.example.invalid/sitemap.xml")!)
        #expect(
            urls.map(\.absoluteString) == [
                "https://synthetic.example.invalid/one", "https://synthetic.example.invalid/two",
            ])
    }
}

private final class SitemapAdmissionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/xml"])!
        let oversized = "https://synthetic.example.invalid/" + String(repeating: "x", count: 5_000)
        let locations = [
            "file:///tmp/private", "https://user:secret@synthetic.example.invalid/", oversized,
            "https://synthetic.example.invalid/one", "https://synthetic.example.invalid/two",
            "https://synthetic.example.invalid/three",
        ]
        let body =
            "<urlset>" + locations.map { "<url><loc>\($0)</loc></url>" }.joined() + "</urlset>"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8));
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
