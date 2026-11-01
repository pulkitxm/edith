import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostDevelopmentCatalogTests {
    private let key = Data(repeating: 7, count: 32).base64EncodedString()

    private func catalog(_ location: String, development: Bool = true, key: String? = nil)
        -> HostDevelopmentCatalog?
    {
        HostDevelopmentCatalog(
            environment: [
                HostDevelopmentCatalog.locationKey: location,
                HostDevelopmentCatalog.publicKeyKey: key ?? self.key,
            ], development: development)
    }

    @Test func acceptsOnlyLoopbackCatalogsInDevelopmentBuilds() {
        #expect(catalog("http://127.0.0.1:47321") != nil)
        #expect(catalog("http://localhost:47321") != nil)
        #expect(catalog("http://127.0.0.1:47321", development: false) == nil)
        #expect(catalog("https://127.0.0.1:47321") == nil)
        #expect(catalog("http://example.com:47321") == nil)
        #expect(catalog("http://127.0.0.1:47321?x=1") == nil)
        #expect(catalog("http://127.0.0.1:47321", key: "c2hvcnQ=") == nil)
        #expect(
            HostDevelopmentCatalog(environment: [:], development: true) == nil)
    }

    @Test func mapsReleaseDownloadsToTheLocalServer() throws {
        let local = try #require(catalog("http://127.0.0.1:47321"))
        #expect(local.catalogURL.absoluteString == "http://127.0.0.1:47321/catalog.json")
        let release = try #require(
            URL(string: "https://github.com/pulkitxm/edith/releases/download/jev-1.0.5-abc/jev.zip")
        )
        #expect(
            local.localURL(for: release, repository: "pulkitxm/edith")?.absoluteString
                == "http://127.0.0.1:47321/releases/jev-1.0.5-abc/jev.zip")
        let foreign = try #require(
            URL(string: "https://github.com/other/repo/releases/download/t/jev.zip"))
        #expect(local.localURL(for: foreign, repository: "pulkitxm/edith") == nil)
        let traversal = try #require(
            URL(string: "https://github.com/pulkitxm/edith/releases/download/../x/jev.zip"))
        #expect(local.localURL(for: traversal, repository: "pulkitxm/edith") == nil)
    }
}
