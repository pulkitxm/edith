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

@Test func aNewSigningKeyRecoversThePreviousAppsCatalogCache() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let oldKey = Curve25519.Signing.PrivateKey()
    let newKey = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(
        ExtensionCatalog(revision: 3, packages: [fixturePackage()]))
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    let old = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: oldKey.signature(for: payload)))
    try old.write(to: cache)
    let current = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: newKey.signature(for: payload)))
    let client = ExtensionCatalogClient(
        url: URL(string: "https://github.com/example/app/catalog")!,
        publicKey: newKey.publicKey.rawRepresentation, repository: "example/app", cache: cache,
        fetch: { _ in current })
    #expect(try await client.refresh().catalog.revision == 3)
    #expect(try Data(contentsOf: cache) == current)
}

private actor CatalogRequests {
    var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
}

private func catalogRelease(_ data: Data, revision: Int64, changes: [String: Any] = [:]) throws
    -> Data
{
    var pointer: [String: Any] = [
        "schemaVersion": 1, "revision": revision, "assetName": "catalog-\(revision).json",
        "bytes": data.count,
        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
    ]
    for (key, value) in changes { pointer[key] = value }
    let body = String(data: try JSONSerialization.data(withJSONObject: pointer), encoding: .utf8)!
    return try JSONSerialization.data(withJSONObject: [
        "body": body, "draft": false, "tag_name": "synthetic-catalog",
        "assets": [["name": "catalog-\(revision).json", "size": data.count]],
    ])
}

@Test func productionCatalogResolutionUsesOnlyTheFixedReleaseAndImmutableAsset() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(
        ExtensionCatalog(revision: 2, packages: [fixturePackage()]))
    let data = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
    let metadata = try catalogRelease(data, revision: 2)
    let requests = CatalogRequests()
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    let client = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { url in
        await requests.append(url)
        return url.host == "api.github.com" ? metadata : data
    }
    #expect(try await client.refresh().catalog.revision == 2)
    #expect(try Data(contentsOf: cache) == data)
    #expect(
        await requests.urls.map(\.absoluteString) == [
            "https://api.github.com/repos/example/app/releases/tags/synthetic-catalog",
            "https://github.com/example/app/releases/download/synthetic-catalog/catalog-2.json",
        ])
    let offline = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in throw MarketplaceError.downloadFailed }
    #expect(try await offline.refresh().offline)
}

@Test func invalidPointersAndSignedRevisionMismatchesCannotReplaceTheCachedCatalog() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(
        ExtensionCatalog(revision: 2, packages: [fixturePackage()]))
    let data = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    try data.write(to: cache)
    let mutations: [[String: Any]] = [
        ["schemaVersion": 2], ["revision": 0], ["bytes": 0], ["bytes": 3_145_729],
        ["assetName": "../catalog-2.json"], ["sha256": String(repeating: "a", count: 64)],
        ["url": "https://foreign.invalid/catalog"],
    ]
    for change in mutations {
        let metadata = try catalogRelease(data, revision: 2, changes: change)
        let client = ExtensionCatalogClient(
            releaseRepository: "example/app", catalogTag: "synthetic-catalog",
            publicKey: key.publicKey.rawRepresentation, cache: cache
        ) { url in url.host == "api.github.com" ? metadata : data }
        await #expect(throws: (any Error).self) { try await client.refresh() }
        #expect(try Data(contentsOf: cache) == data)
    }
    for revision in [1, 3] {
        let metadata = try catalogRelease(data, revision: Int64(revision))
        let client = ExtensionCatalogClient(
            releaseRepository: "example/app", catalogTag: "synthetic-catalog",
            publicKey: key.publicKey.rawRepresentation, cache: cache
        ) { url in url.host == "api.github.com" ? metadata : data }
        await #expect(throws: MarketplaceError.invalidCatalog) { try await client.refresh() }
        #expect(try Data(contentsOf: cache) == data)
    }
}

@Test func releaseMetadataRejectsDraftsDuplicateAssetsAndLegacyEnvelopeFallbacks() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(ExtensionCatalog(revision: 1, packages: []))
    let data = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
    let valid =
        try JSONSerialization.jsonObject(with: catalogRelease(data, revision: 1)) as! [String: Any]
    for change: [String: Any] in [
        ["draft": true], ["tag_name": "foreign"], ["body": ""],
        ["assets": []],
        ["assets": (valid["assets"] as! [[String: Any]]) + (valid["assets"] as! [[String: Any]])],
        [
            "body": (valid["body"] as! String).replacingOccurrences(
                of: "\"revision\":1", with: "\"revision\":0,\"revision\":1")
        ],
    ] {
        let metadata = try JSONSerialization.data(
            withJSONObject: valid.merging(change) { _, value in value })
        let requests = CatalogRequests()
        let client = ExtensionCatalogClient(
            releaseRepository: "example/app", catalogTag: "synthetic-catalog",
            publicKey: key.publicKey.rawRepresentation,
            cache: fixture.directory.appendingPathComponent("cache")
        ) { url in
            await requests.append(url)
            return metadata
        }
        await #expect(throws: (any Error).self) { try await client.refresh() }
        #expect(await requests.urls.count == 1)
    }
    let client = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation,
        cache: fixture.directory.appendingPathComponent("cache")
    ) { _ in data }
    await #expect(throws: (any Error).self) { try await client.refresh() }
}

@Test func pointerHashesDoNotReplacePublisherTrustAndCancelledDownloadsPreserveTheCache()
    async throws
{
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let payload = try JSONEncoder().encode(ExtensionCatalog(revision: 2, packages: []))
    let data = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    try data.write(to: cache)
    let foreign = Curve25519.Signing.PrivateKey()
    let forged = try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: foreign.signature(for: payload)))
    let metadata = try catalogRelease(forged, revision: 2)
    let untrusted = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { url in url.host == "api.github.com" ? metadata : forged }
    await #expect(throws: MarketplaceError.invalidSignature) { try await untrusted.refresh() }
    #expect(try Data(contentsOf: cache) == data)
    let validMetadata = try catalogRelease(data, revision: 2)
    let missingAsset = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { url in
        if url.host == "api.github.com" { return validMetadata }
        throw MarketplaceError.downloadFailed
    }
    #expect(try await missingAsset.refresh().offline)
    let (events, continuation) = AsyncStream<Void>.makeStream()
    let cancelled = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { url in
        if url.host == "api.github.com" { return validMetadata }
        continuation.yield(())
        try await Task.sleep(for: .seconds(30))
        return data
    }
    let task = Task { try await cancelled.refresh() }
    var iterator = events.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: cache) == data)
}
