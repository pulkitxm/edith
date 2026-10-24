import Foundation
import Testing

@testable import EdithKit

struct SocialAccountTests {
    @Test func websitesRequireHTTPSAndRejectEmbeddedCredentials() throws {
        #expect(
            try SocialPlatform.websiteURL(" instagram.com ").absoluteString
                == "https://instagram.com")
        for address in [
            "http://example.com", "file:///etc/passwd", "javascript:alert(1)",
            "https://user:pass@example.com", "",
        ] {
            #expect(throws: SocialAccountError.self) { try SocialPlatform.websiteURL(address) }
        }
    }

    @Test func accountsRetainIndependentIdentitiesAcrossRestartsAndRenames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SocialAccountFile(url: folder.appendingPathComponent("accounts.json"))
        var catalog = try file.load()
        let platform = try #require(catalog.platforms.first)
        catalog.profiles = [SocialProfile(name: "Studio")]
        catalog.accounts = (1...6).map {
            SocialAccount(
                profileID: catalog.profiles[0].id, platformID: platform.id, name: "Account \($0)")
        }
        try file.save(catalog)
        let restored = try file.load()
        #expect(restored == catalog)
        #expect(Set(restored.accounts.map(\.id)).count == 6)
        catalog.accounts[0].name = "Renamed"
        try file.save(catalog)
        #expect(try file.load().accounts[0].id == restored.accounts[0].id)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func corruptListsAreNotSilentlyReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SocialAccountFile(url: folder.appendingPathComponent("accounts.json"))
        try Data("invalid".utf8).write(to: file.url)
        #expect(throws: (any Error).self) { try file.load() }
        var catalog = SocialAccountCatalog()
        catalog.accounts = [SocialAccount(profileID: UUID(), platformID: UUID(), name: "Orphan")]
        #expect(throws: SocialAccountError.self) { try file.save(catalog) }
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "invalid")
    }
}
