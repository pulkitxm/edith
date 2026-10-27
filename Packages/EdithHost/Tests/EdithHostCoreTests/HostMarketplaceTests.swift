import CryptoKit
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHostCore
import HostWorkerFixtureSupport

@Suite @MainActor struct HostMarketplaceTests {
    @Test func aNewProtocolRefreshesTheCatalogEvenWhenThePreviousCheckIsRecent() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let now = Date()
        let defaults = try #require(UserDefaults(suiteName: fixture.identity.defaultsSuite))
        defaults.set(now, forKey: HostMarketplace.lastCatalogRefreshKey)
        defaults.set("previous-protocol", forKey: HostMarketplace.lastCatalogCompatibilityKey)
        try fixture.envelope(packages: [fixture.package("1.0.0", abi: "previous-protocol")])
            .write(to: fixture.cache)
        await fixture.network.set(
            data: try fixture.envelope(packages: [fixture.package("1.1.0")], revision: 2))
        let marketplace = try fixture.marketplace()
        await marketplace.loadCachedCatalog()
        #expect(marketplace.available.isEmpty)
        await marketplace.refreshCatalogIfStale(now: now)
        #expect(await fixture.network.count == 1)
        #expect(marketplace.available["sample"]?.hostABI == HostContract.compatibility)
        await marketplace.refreshCatalogIfStale(now: now.addingTimeInterval(60))
        #expect(await fixture.network.count == 1)
    }

    @Test func aNewProtocolChecksInstalledUpdatesWithoutWaitingForTheNextScheduledCheck()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let now = Date()
        try fixture.store.commit([fixture.package("1.0.0")])
        let defaults = try #require(UserDefaults(suiteName: fixture.identity.defaultsSuite))
        defaults.set(now, forKey: "lastAutomaticExtensionCheck")
        defaults.set("same-build", forKey: "lastAutomaticExtensionCheckHostBuild")
        defaults.set("previous-protocol", forKey: "lastAutomaticExtensionCheckHostABI")
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        let marketplace = try fixture.marketplace()
        await marketplace.updateInstalledIfDue(now: now, hostBuild: "same-build")
        #expect(await fixture.network.count == 1)
        await marketplace.updateInstalledIfDue(
            now: now.addingTimeInterval(60), hostBuild: "same-build")
        #expect(await fixture.network.count == 1)
    }

    @Test func failedActivationExplainsTheCauseAndRetainsTheDownloadForRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        var attempts = 0
        let marketplace = try fixture.marketplace { _ in
            attempts += 1
            return attempts == 1 ? "reject-start-with-reason" : "normal"
        }
        await marketplace.enable(id: "sample")
        #expect(marketplace.error == "Screen Recording permission is required.")
        #expect(marketplace.sessions.states["sample"] == .failed)
        #expect(marketplace.sessions.activeIDs.isEmpty)
        #expect(marketplace.installed["sample"] == fixture.package("1.0.0"))
        #expect(!marketplace.busy)
        await marketplace.enable(id: "sample")
        #expect(marketplace.sessions.activeIDs == ["sample"])
        #expect(marketplace.error == nil)
        #expect(marketplace.sessions.failureReasons["sample"] == nil)
        #expect(await fixture.network.count == 0)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func downloadsOfDifferentExtensionsRunTogetherWithTheirOwnStateAndOneCatalogFetch()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let packages = [fixture.package("1.0.0"), fixture.package("1.0.0", id: "second")]
        await fixture.network.set(data: try fixture.envelope(packages: packages))
        await fixture.network.block()
        let marketplace = try fixture.marketplace(ids: ["sample", "second"])
        let first = Task { await marketplace.download(id: "sample") }
        let second = Task { await marketplace.download(id: "second") }
        while await fixture.network.count == 0 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(marketplace.isBusy("sample") && marketplace.isBusy("second"))
        #expect(await marketplace.download(id: "sample") == nil)
        await fixture.network.release()
        let failures = [await first.value, await second.value]
        #expect(failures.allSatisfy { $0 != nil })
        #expect(await fixture.network.count == 1)
        #expect(Set(await fixture.archives.urls) == Set(packages.map(\.downloadURL)))
        #expect(Set(marketplace.failures.keys) == ["sample", "second"])
        #expect(!marketplace.busy)
    }

    @Test func installingSeveralExtensionsReportsEachFailureSeparately() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ids = ["sample", "second", "third", "fourth", "fifth"]
        await fixture.network.set(
            data: try fixture.envelope(packages: ids.map { fixture.package("1.0.0", id: $0) }))
        let marketplace = try fixture.marketplace(ids: ids)
        let failures = await marketplace.install(ids: ids)
        #expect(Set(failures.keys) == Set(ids))
        #expect(await fixture.archives.urls.count == ids.count)
        #expect(!marketplace.busy)
    }

    @Test func installedExtensionsRemainUsableDuringASharedSlowCatalogRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        await fixture.network.block()
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let first = Task { await marketplace.checkForUpdates() }
        while await fixture.network.count == 0 { await Task.yield() }
        let second = Task { await marketplace.checkForUpdates() }
        #expect(marketplace.refreshingCatalog)
        #expect(!marketplace.busy)
        await marketplace.enable(id: "sample")
        #expect(marketplace.sessions.activeIDs == ["sample"])
        await marketplace.disable(id: "sample")
        #expect(marketplace.sessions.activeIDs.isEmpty)
        await fixture.network.release()
        await first.value
        await second.value
        #expect(await fixture.network.count == 1)
        #expect(!marketplace.refreshingCatalog)
        #expect(marketplace.error == nil)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func remoteSettingsAdmissionDoesNotDownloadOrStartADisabledEngine() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace()
        let manager = HostRemoteSessionManager(marketplace: marketplace)
        let settings = HostExtensionContentRequest(
            extensionID: "sample", location: "settings", section: "extension")
        let configuration = try manager.selectedConfiguration(for: settings)
        #expect(configuration.uiOnly)
        #expect(configuration.package == fixture.package("1.0.0"))
        for location in ["main", "home", "notch", "sidebar.utility"] {
            let request = HostExtensionContentRequest(extensionID: "sample", location: location)
            await #expect(throws: HostWorkerError.rejected) {
                try await manager.scene(for: request)
            }
        }
        #expect(marketplace.sessions.enabledIDs.isEmpty)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        #expect(await fixture.network.count == 0)
    }

    @Test func remoteFeatureAdmissionTracksTheCurrentWorkerAndPendingDisable() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let package = fixture.package("1.0.0")
        try fixture.store.commit([package])
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let manager = HostRemoteSessionManager(marketplace: marketplace)
        let request = HostExtensionContentRequest(
            extensionID: "sample", location: "main", section: "sample")
        try await marketplace.sessions.enable(package)
        #expect(try !manager.selectedConfiguration(for: request).uiOnly)
        marketplace.sessions.requestDisable(ids: ["sample"])
        #expect(throws: HostWorkerError.rejected) {
            try manager.selectedConfiguration(for: request)
        }
        let settings = HostExtensionContentRequest(
            extensionID: "sample", location: "settings", section: "extension")
        #expect(throws: HostWorkerError.rejected) {
            try manager.selectedConfiguration(for: settings)
        }
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func remoteEngineOwnershipRejectsDisabledPendingAndReplacedWorkers() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let package = fixture.package("1.0.0")
        try fixture.store.commit([package])
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let manager = HostRemoteSessionManager(marketplace: marketplace)
        let settings = HostExtensionContentRequest(
            extensionID: "sample", location: "settings", section: "extension")
        #expect(throws: HostWorkerError.rejected) {
            try HostRemoteEngineOwner(
                marketplace: marketplace,
                configuration: manager.selectedConfiguration(for: settings))
        }
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        try await marketplace.sessions.enable(package)
        let request = HostExtensionContentRequest(extensionID: "sample", location: "main")
        let owner = try HostRemoteEngineOwner(
            marketplace: marketplace,
            configuration: manager.selectedConfiguration(for: request))
        try owner.validate()
        marketplace.sessions.requestDisable(ids: ["sample"])
        #expect(throws: HostWorkerError.rejected) { try owner.validate() }
        try await marketplace.sessions.disable(id: "sample")
        try await marketplace.sessions.enable(package)
        #expect(throws: HostWorkerError.rejected) { try owner.validate() }
        let replacement = try HostRemoteEngineOwner(
            marketplace: marketplace,
            configuration: manager.selectedConfiguration(for: request))
        try replacement.validate()
        #expect(await marketplace.sessions.shutdown())
        #expect(await fixture.network.count == 0)
    }

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

    @Test func anEmptyMarketplaceFetchesTheCatalogWhenNoneIsCached() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        let marketplace = try fixture.marketplace()
        await marketplace.loadCachedCatalog()
        let now = Date()
        await marketplace.refreshCatalogIfStale(now: now)
        #expect(await fixture.network.count == 1)
        #expect(marketplace.available["sample"]?.version == "1.0.0")
        #expect(marketplace.installed.isEmpty)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        await marketplace.refreshCatalogIfStale(now: now.addingTimeInterval(60))
        #expect(await fixture.network.count == 1)
        await marketplace.refreshCatalogIfStale(now: now.addingTimeInterval(9 * 60 * 60))
        #expect(await fixture.network.count == 2)
    }

    @Test func aCachedCatalogWithoutARecordedRefreshIsRefreshed() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let envelope = try fixture.envelope(packages: [fixture.package("1.0.0")])
        try FileManager.default.createDirectory(
            at: fixture.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try envelope.write(to: fixture.cache)
        await fixture.network.set(data: envelope)
        let marketplace = try fixture.marketplace()
        await marketplace.loadCachedCatalog()
        #expect(await fixture.network.count == 0)
        await marketplace.refreshCatalogIfStale()
        #expect(await fixture.network.count == 1)
        let restarted = try fixture.marketplace()
        await restarted.loadCachedCatalog()
        await restarted.refreshCatalogIfStale()
        #expect(await fixture.network.count == 1)
    }

    @Test func anOfflineCatalogRefreshIsRetriedOnTheNextVisit() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let marketplace = try fixture.marketplace()
        await marketplace.refreshCatalogIfStale()
        #expect(await fixture.network.count == 1)
        #expect(marketplace.error != nil)
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        await marketplace.refreshCatalogIfStale()
        #expect(await fixture.network.count == 2)
        #expect(marketplace.available["sample"] != nil)
        #expect(marketplace.error == nil)
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

    @Test func aNewAppBuildChecksExtensionUpdatesImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0")])
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        let marketplace = try fixture.marketplace()
        let now = Date()
        await marketplace.updateInstalledIfDue(now: now, hostBuild: "331")
        await marketplace.updateInstalledIfDue(now: now.addingTimeInterval(60), hostBuild: "331")
        #expect(await fixture.network.count == 1)
        await marketplace.updateInstalledIfDue(now: now.addingTimeInterval(120), hostBuild: "332")
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

    @Test func anInstalledPackageRequiringANewerSystemIsNotOfferedOrRestored() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let future = fixture.package(
            "1.0.0",
            minimumSystemVersion: .init(
                major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion + 1))
        try fixture.install([future])
        let defaults = try #require(UserDefaults(suiteName: fixture.identity.defaultsSuite))
        defaults.set(["sample"], forKey: "enabledExtensions")
        let marketplace = try fixture.marketplace()
        await marketplace.restoreEnabledExtensions()
        #expect(marketplace.downloadedIDs == ["sample"])
        #expect(marketplace.installed.isEmpty)
        #expect(marketplace.sessions.states["sample"] == .notInstalled)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
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
        #expect(!marketplace.busy)
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

    @Test(arguments: ["version", "fingerprint", "hash", "abi", "architecture", "size", "id"])
    func reviewedDownloadRejectsTheChangedSignedCandidateBeforeArchiveTransfer(field: String)
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let reviewed = fixture.package("1.0.0")
        await fixture.network.set(data: try fixture.envelope(packages: [reviewed]))
        let marketplace = try fixture.marketplace()
        await marketplace.checkForUpdates()
        #expect(marketplace.available["sample"] == reviewed)
        let changed = ExtensionPackage(
            id: "sample", version: field == "version" ? "2.0.0" : reviewed.version,
            hostABI: field == "abi" ? "different-abi" : reviewed.hostABI,
            architecture: field == "architecture" ? "x86_64" : reviewed.architecture,
            minimumSystemVersion: reviewed.minimumSystemVersion,
            downloadURL: field == "fingerprint"
                ? URL(
                    string:
                        "https://github.com/pulkitxm/edith/releases/download/extension-sample-1.0.0-newfingerprint/sample.zip"
                )!
                : reviewed.downloadURL,
            sha256: field == "hash" ? String(repeating: "b", count: 64) : reviewed.sha256,
            downloadBytes: field == "size" ? 2 : reviewed.downloadBytes,
            installedBytes: reviewed.installedBytes)
        await fixture.network.set(data: try fixture.envelope(packages: [changed], revision: 2))
        await marketplace.download(
            id: field == "id" ? "other" : "sample", expectedPackage: reviewed)
        #expect(marketplace.error?.contains("package changed") == true)
        #expect(await fixture.archives.urls.isEmpty)
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
        #expect(!marketplace.busy)
        #expect(await fixture.network.count == 2)
    }

    @Test func unchangedReviewedCandidateReachesOnlyItsPinnedArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let reviewed = fixture.package("1.0.0")
        await fixture.network.set(data: try fixture.envelope(packages: [reviewed]))
        let marketplace = try fixture.marketplace()
        await marketplace.download(id: "sample", expectedPackage: reviewed)
        #expect(await fixture.archives.urls == [reviewed.downloadURL])
        #expect(marketplace.error?.contains("package changed") == false)
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(marketplace.sessions.processIdentifiers.isEmpty)
    }

    @Test func rejectedReviewPreservesSelectedAndRetainedVersions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let old = fixture.package("1.0.0"), reviewed = fixture.package("2.0.0")
        try fixture.install([old, reviewed])
        try fixture.store.select(old)
        let changed = fixture.package("3.0.0")
        await fixture.network.set(data: try fixture.envelope(packages: [changed], revision: 2))
        let marketplace = try fixture.marketplace()
        await marketplace.download(id: "sample", expectedPackage: reviewed)
        #expect(await fixture.archives.urls.isEmpty)
        #expect(Set(try fixture.store.installedPackages().map(\.version)) == ["1.0.0", "2.0.0"])
        #expect(marketplace.installed["sample"] == old)
        #expect(
            try fixture.store.installedPackage(
                id: "sample", hostABI: HostContract.compatibility, architecture: "arm64") == old)
    }

    private actor ArchiveRequests {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    private actor Network {
        private(set) var count = 0
        private var data: Data?
        private var blocked = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func set(data: Data) { self.data = data }
        func block() { blocked = true }
        func release() {
            blocked = false
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        func fetch() async throws -> Data {
            count += 1
            if blocked { await withCheckedContinuation { waiters.append($0) } }
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
        let archives = ArchiveRequests()
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

        func marketplace(
            ids: [String] = ["sample"], workerMode: ((ExtensionPackage) -> String)? = nil
        ) throws
            -> HostMarketplace
        {
            let defaults = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            let sessions = HostExtensionSessions(defaults: defaults) { package in
                guard let workerMode else { throw HostWorkerError.rejected }
                return HostWorker(
                    configuration: HostWorkerConfiguration(
                        identity: identity, extensionID: package.id, version: package.version),
                    requestTimeout: .seconds(2),
                    engine: FixtureWorkerEngine.factory(mode: workerMode(package)))
            }
            let client = ExtensionCatalogClient(
                url: URL(string: "https://github.com/pulkitxm/edith/catalog")!,
                publicKey: key.publicKey.rawRepresentation,
                repository: MarketplaceConfiguration.repository, cache: cache,
                fetch: { [network] _ in try await network.fetch() })
            let installer = ExtensionPackageInstaller(
                store: store,
                download: { [archives] url, _ in
                    await archives.record(url)
                    throw MarketplaceError.downloadFailed
                }, verify: { _ in })
            return try HostMarketplace(
                identity: identity,
                entries: ids.map {
                    HostExtension(id: $0, title: $0, symbolName: "square", category: "Tools")
                }, store: store, catalogClient: client, installer: installer, sessions: sessions)
        }

        func package(
            _ version: String, abi: String = HostContract.compatibility,
            minimumSystemVersion: ExtensionSystemVersion = .init(major: 14), id: String = "sample"
        )
            -> ExtensionPackage
        {
            ExtensionPackage(
                id: id, version: version, hostABI: abi,
                minimumSystemVersion: minimumSystemVersion,
                downloadURL: URL(
                    string: "https://github.com/pulkitxm/edith/releases/download/fixture/\(id).zip"
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
