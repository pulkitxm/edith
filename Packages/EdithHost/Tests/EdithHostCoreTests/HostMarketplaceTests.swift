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

    @Test func failedStartsPersistRollbackThroughRestartAndPruningThenAllowRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let old = fixture.package("1.0.0")
        let first = fixture.package("1.1.0")
        let next = fixture.package("1.2.0")
        try fixture.install([old, first, next])
        try fixture.store.select(old)
        var rejectUpdates = true
        let makeMode: (ExtensionPackage) -> String = {
            rejectUpdates && $0.version != old.version ? "reject" : "normal"
        }
        let marketplace = try fixture.marketplace(workerMode: makeMode)
        await marketplace.enable(id: "sample")
        #expect(marketplace.sessions.versions["sample"] == old.version)
        await fixture.network.set(data: try fixture.envelope(packages: [first], revision: 1))
        await marketplace.download(id: "sample")
        #expect(marketplace.error != nil)
        #expect(marketplace.sessions.versions["sample"] == old.version)
        await fixture.network.set(data: try fixture.envelope(packages: [next], revision: 2))
        await marketplace.download(id: "sample")
        #expect(marketplace.installed["sample"] == old)
        #expect(try fixture.store.installedPackages().contains(old))
        #expect(await marketplace.sessions.shutdown())

        let restartedStore = ExtensionPackageStore(root: fixture.store.root)
        #expect(
            try restartedStore.installedPackage(
                id: "sample", hostABI: HostContract.compatibility, architecture: "arm64") == old)
        let restarted = try fixture.marketplace(workerMode: makeMode)
        await restarted.restoreEnabledExtensions()
        #expect(restarted.sessions.states["sample"] == .active)
        #expect(restarted.sessions.versions["sample"] == old.version)
        await restarted.checkForUpdates()
        #expect(restarted.updateAvailable(id: "sample"))
        rejectUpdates = false
        await restarted.download(id: "sample")
        #expect(restarted.error == nil)
        #expect(restarted.installed["sample"] == next)
        #expect(restarted.sessions.versions["sample"] == next.version)
        #expect(!restarted.updateAvailable(id: "sample"))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: old).path))
        #expect(await restarted.sessions.shutdown())
        let successfulRestart = try fixture.marketplace(workerMode: makeMode)
        await successfulRestart.restoreEnabledExtensions()
        #expect(successfulRestart.sessions.versions["sample"] == next.version)
        #expect(await successfulRestart.sessions.shutdown())
    }

    @Test func updatingADisabledRollbackDoesNotStartWorkersAndRemovalClearsSelection() async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let old = fixture.package("1.0.0")
        let next = fixture.package("1.1.0")
        try fixture.install([old, next])
        try fixture.store.select(old)
        await fixture.network.set(data: try fixture.envelope(packages: [next]))
        var starts = 0
        let marketplace = try fixture.marketplace(workerMode: { _ in
            starts += 1
            return "normal"
        })
        await marketplace.updateInstalledIfDue()
        #expect(marketplace.installed["sample"] == next)
        #expect(starts == 0)
        #expect(marketplace.sessions.enabledIDs.isEmpty)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        await marketplace.remove(id: "sample")
        #expect(marketplace.error == nil)
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(
            try JSONDecoder().decode(
                [ExtensionPackage].self,
                from: Data(
                    contentsOf: fixture.store.root.appendingPathComponent("selected-packages.json"))
            )
            .isEmpty)
        try fixture.install([old, next])
        #expect(
            try fixture.store.installedPackage(
                id: "sample", hostABI: HostContract.compatibility, architecture: "arm64") == next)
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

        func marketplace(workerMode: ((ExtensionPackage) -> String)? = nil) throws
            -> HostMarketplace
        {
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let sessions = HostExtensionSessions(defaults: defaults) { package in
                guard let workerMode else { throw HostWorkerError.rejected }
                let script = try #require(
                    Bundle.module.url(
                        forResource: "worker", withExtension: "py", subdirectory: "Fixtures"))
                return HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [script.path, workerMode(package)], requestTimeout: .seconds(2))
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: key.publicKey.rawRepresentation,
                repository: MarketplaceConfiguration.repository, cache: cache,
                fetch: { [network] _ in try await network.fetch() })
            let installer = ExtensionPackageInstaller(
                store: store, download: { _, _ in throw MarketplaceError.downloadFailed },
                verify: { _ in })
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

        func install(_ packages: [ExtensionPackage]) throws {
            for package in packages {
                try FileManager.default.createDirectory(
                    at: store.directory(for: package), withIntermediateDirectories: true)
            }
            try store.commit(packages)
        }

        func envelope(packages: [ExtensionPackage], revision: Int64 = 1) throws -> Data {
            let payload = try JSONEncoder().encode(
                ExtensionCatalog(revision: revision, packages: packages))
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
