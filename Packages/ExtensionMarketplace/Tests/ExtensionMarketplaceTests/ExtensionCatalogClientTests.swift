import CryptoKit
import Foundation
import Testing
@testable import ExtensionMarketplace

@Test func aVerifiedCatalogRemainsAvailableOffline() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(
        ExtensionCatalog(revision: 1, packages: [fixturePackage()]))
    let data = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    let client = ExtensionCatalogClient(
        url: URL(string: "https://github.com/example/app/catalog")!,
        publicKey: key.publicKey.rawRepresentation, repository: "example/app", cache: cache,
        fetch: { _ in data })
    #expect(try await client.refresh().offline == false)
    let offline = ExtensionCatalogClient(
        url: URL(string: "https://github.com/example/app/catalog")!,
        publicKey: key.publicKey.rawRepresentation, repository: "example/app", cache: cache,
        fetch: { _ in throw MarketplaceError.downloadFailed })
    #expect(try await offline.refresh().offline == true)
    #expect(try await offline.cached()?.packages == [fixturePackage()])
}

@Test func untrustedOrOlderCatalogsCannotReplaceTheCache() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    func envelope(_ revision: Int64) throws -> Data {
        let payload = try JSONEncoder().encode(
            ExtensionCatalog(revision: revision, packages: [fixturePackage()]))
        return try JSONEncoder().encode(
            SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
    }
    let current = try envelope(2)
    let older = try envelope(1)
    try current.write(to: cache)
    let client = ExtensionCatalogClient(
        url: URL(string: "https://github.com/example/app/catalog")!,
        publicKey: key.publicKey.rawRepresentation, repository: "example/app", cache: cache,
        fetch: { _ in older })
    await #expect(throws: MarketplaceError.invalidCatalog) { try await client.refresh() }
    #expect(try Data(contentsOf: cache) == current)
    let untrusted = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: Data(), signature: Data()))
    let unsafeClient = ExtensionCatalogClient(
        url: URL(string: "https://github.com/example/app/catalog")!,
        publicKey: key.publicKey.rawRepresentation, repository: "example/app", cache: cache,
        fetch: { _ in untrusted })
    await #expect(throws: MarketplaceError.invalidSignature) { try await unsafeClient.refresh() }
    #expect(try Data(contentsOf: cache) == current)
}
