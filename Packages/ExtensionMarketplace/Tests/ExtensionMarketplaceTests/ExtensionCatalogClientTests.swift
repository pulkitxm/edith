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
        fetch: { _ in throw URLError(.notConnectedToInternet) })
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

private func signedCatalog(_ key: Curve25519.Signing.PrivateKey, revision: Int64) throws -> Data {
    let payload = try JSONEncoder().encode(
        ExtensionCatalog(revision: revision, packages: [fixturePackage()]))
    return try JSONEncoder().encode(
        SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
}

@Test func productionCatalogResolutionFetchesOnlyTheStableReleaseAsset() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let data = try signedCatalog(key, revision: 2)
    let requests = CatalogRequests()
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    let client = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { url in
        await requests.append(url)
        return data
    }
    let result = try await client.refresh()
    #expect(result.catalog.revision == 2 && result.fallback == nil)
    #expect(try Data(contentsOf: cache) == data)
    #expect(
        await requests.urls.map(\.absoluteString) == [
            "https://github.com/example/app/releases/download/synthetic-catalog/catalog.json"
        ])
}

@Test func invalidReleaseIdentitiesNeverReachTheNetwork() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    for (repository, tag) in [("example", "tag"), ("example/app/extra", "tag"), ("example/app", "../tag")] {
        let requests = CatalogRequests()
        let client = ExtensionCatalogClient(
            releaseRepository: repository, catalogTag: tag,
            publicKey: key.publicKey.rawRepresentation,
            cache: fixture.directory.appendingPathComponent("cache")
        ) { url in
            await requests.append(url)
            return Data()
        }
        await #expect(throws: MarketplaceError.invalidCatalog) { try await client.refresh() }
        #expect(await requests.urls.isEmpty)
    }
}

@Test func rateLimitedFetchesFallBackToTheCacheAndReportTheRealCause() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let data = try signedCatalog(key, revision: 2)
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    try data.write(to: cache)
    let limited = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in throw MarketplaceError.rateLimited }
    let result = try await limited.refresh()
    #expect(result.fallback == .rateLimited && !result.offline && result.catalog.revision == 2)
    let broken = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in throw MarketplaceError.downloadFailed }
    #expect(try await broken.refresh().fallback == .unavailable)
    let disconnected = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in throw URLError(.notConnectedToInternet) }
    #expect(try await disconnected.refresh().offline)
    let uncached = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation,
        cache: fixture.directory.appendingPathComponent("missing")
    ) { _ in throw MarketplaceError.rateLimited }
    await #expect(throws: MarketplaceError.rateLimited) { try await uncached.refresh() }
}

@Test func transientFailuresRetryWithBackoffThenStop() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let data = try signedCatalog(key, revision: 2)
    let requests = CatalogRequests()
    let recovering = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation,
        cache: fixture.directory.appendingPathComponent("cache"),
        retryDelays: [.milliseconds(1), .milliseconds(1)]
    ) { url in
        await requests.append(url)
        if await requests.urls.count < 3 { throw MarketplaceError.rateLimited }
        return data
    }
    #expect(try await recovering.refresh().fallback == nil)
    #expect(await requests.urls.count == 3)
    let exhausted = CatalogRequests()
    let failing = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation,
        cache: fixture.directory.appendingPathComponent("none"),
        retryDelays: [.milliseconds(1), .milliseconds(1)]
    ) { url in
        await exhausted.append(url)
        throw MarketplaceError.rateLimited
    }
    await #expect(throws: MarketplaceError.rateLimited) { try await failing.refresh() }
    #expect(await exhausted.urls.count == 3)
}

@Test func forgedCatalogsAndCancelledDownloadsPreserveTheCache() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let key = Curve25519.Signing.PrivateKey()
    let data = try signedCatalog(key, revision: 2)
    let cache = fixture.directory.appendingPathComponent("catalog.json")
    try data.write(to: cache)
    let forged = try signedCatalog(Curve25519.Signing.PrivateKey(), revision: 3)
    let untrusted = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in forged }
    await #expect(throws: MarketplaceError.invalidSignature) { try await untrusted.refresh() }
    let older = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in try signedCatalog(key, revision: 1) }
    await #expect(throws: MarketplaceError.invalidCatalog) { try await older.refresh() }
    #expect(try Data(contentsOf: cache) == data)
    let (events, continuation) = AsyncStream<Void>.makeStream()
    let cancelled = ExtensionCatalogClient(
        releaseRepository: "example/app", catalogTag: "synthetic-catalog",
        publicKey: key.publicKey.rawRepresentation, cache: cache
    ) { _ in
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
