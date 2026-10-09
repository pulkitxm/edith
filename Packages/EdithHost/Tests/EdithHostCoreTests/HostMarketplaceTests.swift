import CryptoKit
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostMarketplaceTests {
    @Test func bootWithInstalledButDisabledExtensionsUsesNoNetworkOrWorkers() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace()
        await marketplace.loadCachedCatalog()
        await marketplace.restoreEnabledExtensions()
        #expect(await fixture.network.count == 0)
        #expect(marketplace.installed["sample"]?.version == "1.0.0")
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        #expect(marketplace.error == nil)
    }

    @Test func anEmptyMarketplaceDoesNotFetchAutomaticUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let marketplace = try fixture.marketplace()
        await marketplace.updateInstalledIfDue()
        #expect(await fixture.network.count == 0)
    }

    @Test func automaticUpdatePreferencesPersistAcrossAppUpdates() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace()
        marketplace.automaticallyUpdatesExtensions = false
        let restarted = try fixture.marketplace()
        #expect(!restarted.automaticallyUpdatesExtensions)
        await restarted.updateInstalledIfDue()
        #expect(await fixture.network.count == 0)
    }

    @Test func automaticChecksAreRateLimitedAndDoNotEnableDisabledExtensions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        let marketplace = try fixture.marketplace()
        let now = Date()
        await marketplace.updateInstalledIfDue(now: now)
        await marketplace.updateInstalledIfDue(now: now.addingTimeInterval(60))
        #expect(await fixture.network.count == 1)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        await marketplace.updateInstalledIfDue(now: now.addingTimeInterval(9 * 60 * 60))
        #expect(await fixture.network.count == 2)
    }

    @Test func cachedInformationIsVerifiedWithoutFetchingItAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.envelope(packages: [fixture.package("1.1.0")]).write(to: fixture.cache)
        let marketplace = try fixture.marketplace()
        await marketplace.loadCachedCatalog()
        #expect(await fixture.network.count == 0)
        #expect(marketplace.available["sample"]?.version == "1.1.0")
    }

    @Test func appUpdatesRetainInstalledPackagesButDoNotActivateIncompatibleOnes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0", abi: "incompatible")])
        let marketplace = try fixture.marketplace()
        await marketplace.restoreEnabledExtensions()
        #expect(marketplace.installed.isEmpty)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        #expect(try fixture.store.installedPackages().count == 1)
        #expect(await fixture.network.count == 0)
    }

    @Test func failedDownloadsKeepThePreviouslyInstalledVersion() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        let catalog = try fixture.envelope(packages: [fixture.package("1.1.0")])
        await fixture.network.set(data: catalog)
        let marketplace = try fixture.marketplace()
        await marketplace.checkForUpdates()
        #expect(marketplace.updateAvailable(id: "sample"))
        await marketplace.download(id: "sample")
        #expect(marketplace.installed["sample"]?.version == "1.0.0")
        #expect(marketplace.operationID == nil)
        #expect(marketplace.error != nil)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
    }

    private actor Network {
        private(set) var count = 0
        private var data: Data?
        func set(data: Data) { self.data = data }
        func fetch() throws -> Data {
            count += 1
            guard let data else { throw MarketplaceError.downloadFailed }
            return data
        }
    }

    @MainActor private struct Fixture {
        let directory: URL
        let identity: HostIdentity
        let store: ExtensionPackageStore
        let key = Curve25519.Signing.PrivateKey()
        let network = Network()
        var cache: URL { identity.root.appendingPathComponent("catalog.json") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.marketplace-\(UUID().uuidString)",
                supportDirectory: directory)
            store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
            try FileManager.default.createDirectory(
                at: store.root, withIntermediateDirectories: true)
        }

        func marketplace() throws -> HostMarketplace {
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let sessions = HostExtensionSessions(defaults: defaults) { _ in
                throw HostWorkerError.rejected
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: key.publicKey.rawRepresentation,
                repository: MarketplaceConfiguration.repository, cache: cache,
                fetch: { [network] _ in try await network.fetch() })
            let installer = ExtensionPackageInstaller(
                store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                verify: { _ in throw MarketplaceError.invalidSignature })
            return try HostMarketplace(
                identity: identity,
                entries: [
                    HostExtension(
                        id: "sample", title: "Sample", symbolName: "square", category: "Tools")
                ], store: store, catalogClient: client, installer: installer, sessions: sessions)
        }

        func package(_ version: String, abi: String = HostContract.compatibility)
            -> ExtensionPackage
        {
            ExtensionPackage(
                id: "sample", version: version, hostABI: abi,
                downloadURL: URL(
                    string: "https://github.com/pulkitxm/edith/releases/download/fixture/sample.zip"
                )!, sha256: String(repeating: "a", count: 64), downloadBytes: 1, installedBytes: 1)
        }

        func envelope(packages: [ExtensionPackage]) throws -> Data {
            let payload = try JSONEncoder().encode(
                ExtensionCatalog(revision: 1, packages: packages))
            return try JSONEncoder().encode(
                SignedExtensionCatalog(payload: payload, signature: key.signature(for: payload)))
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: identity.defaultsSuite)?.removePersistentDomain(
                forName: identity.defaultsSuite)
        }
    }
}
