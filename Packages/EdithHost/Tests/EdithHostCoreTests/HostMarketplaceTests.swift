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

    @Test func aRateLimitedRefreshKeepsTheCachedCatalogAndNamesTheCause() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.envelope(packages: [fixture.package("1.0.0")]).write(to: fixture.cache)
        await fixture.network.fail(with: MarketplaceError.rateLimited)
        let marketplace = try fixture.marketplace()
        await marketplace.checkForUpdates()
        #expect(marketplace.available["sample"] != nil)
        #expect(!marketplace.offline)
        #expect(marketplace.error?.contains("limiting requests") == true)
        await fixture.network.fail(with: URLError(.notConnectedToInternet))
        await marketplace.checkForUpdates()
        #expect(marketplace.offline)
        #expect(marketplace.error == nil)
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

    @Test func theWorkerContractIsTheOneSignedByTheCurrentTeam() {
        #expect(HostContract.compatibility == "edith-host-6")
    }

    @Test func extensionsInstalledForThePreviousContractMoveToTheCurrentOneOnLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let previous = fixture.package("1.0.0", abi: "edith-host-5")
        try fixture.install([previous])
        let current = try fixture.build("1.0.0")
        await fixture.network.set(
            data: try fixture.envelope(packages: [previous, current.package]))
        let marketplace = try fixture.marketplace(
            serving: [current.package.downloadURL: current.archive])
        #expect(marketplace.installed["sample"] == nil)
        await marketplace.updateInstalledIfDue(now: Date(), hostBuild: "build")
        #expect(marketplace.installed["sample"] == current.package)
        #expect(marketplace.error == nil)
    }

    @Test func extensionsWithNoCompatibleInstallMigrateEvenWhenAutomaticUpdatesAreOff()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let previous = fixture.package("1.0.0", abi: "edith-host-5")
        try fixture.install([previous])
        let current = try fixture.build("1.0.0")
        await fixture.network.set(
            data: try fixture.envelope(packages: [previous, current.package]))
        let marketplace = try fixture.marketplace(
            serving: [current.package.downloadURL: current.archive])
        marketplace.automaticallyUpdatesExtensions = false
        await marketplace.updateInstalledIfDue(now: Date(), hostBuild: "build")
        #expect(marketplace.installed["sample"] == current.package)
        #expect(marketplace.sessions.activeIDs.isEmpty)
        #expect(await marketplace.sessions.shutdown())
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

    @Test func retryingAnExtensionThatCannotStartMovesItToTheCatalogUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let old = fixture.package("1.0.0")
        try fixture.install([old])
        let sideload = try fixture.build("1.1.0")
        await fixture.network.set(data: try fixture.envelope(packages: [sideload.package]))
        let marketplace = try fixture.marketplace(
            workerMode: { $0.version == old.version ? "reject-start-with-reason" : "normal" },
            serving: [sideload.package.downloadURL: sideload.archive])
        await marketplace.checkForUpdates()
        #expect(marketplace.updateAvailable(id: "sample"))
        #expect(await marketplace.enable(id: "sample") == nil)
        #expect(marketplace.installed["sample"] == sideload.package)
        #expect(marketplace.sessions.activeIDs == ["sample"])
        #expect(marketplace.sessions.versions["sample"] == "1.1.0")
        #expect(marketplace.error == nil)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func aFailedStartWithoutAnUpdateReportsTheRealReason() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.install([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace(workerMode: { _ in "reject-start-with-reason" })
        let failure = await marketplace.enable(id: "sample")
        #expect(failure == "Screen Recording permission is required.")
        #expect(marketplace.failures["sample"] == failure)
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

    @Test func aTransferThatFailsTwiceInTransitIsRetried() async throws {
        var attempts = 0
        let value = try await HostMarketplace.retryingTransfer { () async throws -> Int in
            attempts += 1
            if attempts < 3 { throw MarketplaceError.downloadFailed }
            return attempts
        }
        #expect(value == 3)
        await #expect(throws: MarketplaceError.invalidCatalog) {
            try await HostMarketplace.retryingTransfer { () async throws -> Int in
                throw MarketplaceError.invalidCatalog
            }
        }
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
        #expect(Set(await fixture.archives.urls).count == ids.count)
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
        #expect(Set(await fixture.archives.urls) == [reviewed.downloadURL])
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
        private var failure: Error?
        func set(data: Data) { self.data = data }
        func fail(with error: Error?) { failure = error }
        func block() { blocked = true }
        func release() {
            blocked = false
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        func fetch() async throws -> Data {
            count += 1
            if blocked { await withCheckedContinuation { waiters.append($0) } }
            if let failure { throw failure }
            guard let data else { throw MarketplaceError.downloadFailed }
            return data
        }
    }

    @Test func onlyDevelopmentBuildsAcceptSideloadedPackages() async throws {
        #expect(HostMarketplace.allowsSideload(identifier: "com.pulkit.edith.dev.main"))
        #expect(!HostMarketplace.allowsSideload(identifier: "com.pulkit.edith"))
        #expect(!HostMarketplace.allowsSideload(identifier: "com.pulkit.edith.tests.sample"))
        let fixture = try Fixture()
        defer { fixture.clean() }
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let sideload = try fixture.build("1.0.9")
        let error = await #expect(throws: HostCLIError.self) {
            try await marketplace.sideload(sideload, admit: { _ in })
        }
        #expect(error?.errorDescription == "Only development builds can sideload extensions.")
        #expect(marketplace.installed.isEmpty)
    }

    @Test func aSideloadBuiltForAnotherHostContractIsRejected() async throws {
        let fixture = try Fixture(identifier: "com.pulkit.edith.dev.sideload-\(UUID().uuidString)")
        defer { fixture.clean() }
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let sideload = try fixture.build("1.0.9", abi: "edith-host-previous")
        await #expect(throws: HostCLIError.self) {
            try await marketplace.sideload(sideload, admit: { _ in })
        }
        #expect(marketplace.installed.isEmpty)
        #expect(!marketplace.busy)
    }

    @Test func sideloadCommandResolvesRelativePathsAndReportsTheInstalledBuild() async throws {
        let fixture = try Fixture(identifier: "com.pulkit.edith.dev.sideload-\(UUID().uuidString)")
        defer { fixture.clean() }
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let sideload = try fixture.build("1.0.9")
        for arguments in [[String](), ["a", "b"]] {
            await #expect(throws: HostCLIError.self) {
                try await HostSideloadCLI.execute(
                    arguments, marketplace: marketplace, workingDirectory: "/", admit: { _ in })
            }
        }
        let reply = try await HostSideloadCLI.execute(
            ["sample.zip", "--json"], marketplace: marketplace,
            workingDirectory: sideload.archive.deletingLastPathComponent().path,
            admit: { _ in })
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "sample")
        #expect(object["version"] as? String == "1.0.9")
        #expect(object["running"] as? Bool == true)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func theClientStagesAVerifiedPackageWhereTheAppCanReadIt() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let sideload = try fixture.build("1.0.9")
        let staging = fixture.directory.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = try HostSideloadCLI.stage(
            ["sample.zip", "--json"],
            workingDirectory: sideload.archive.deletingLastPathComponent().path,
            temporaryDirectory: staging)
        #expect(staged.directory.deletingLastPathComponent().path == staging.path)
        #expect(staged.arguments.last == "--json")
        let copy = try ExtensionSideload(path: URL(fileURLWithPath: staged.arguments[0]))
        #expect(copy.package == sideload.package)
        var bytes = try Data(contentsOf: sideload.archive)
        bytes[0] ^= 0xFF
        try bytes.write(to: sideload.archive)
        #expect(throws: HostCLIError.self) {
            try HostSideloadCLI.stage(
                [sideload.archive.path], workingDirectory: "/", temporaryDirectory: staging)
        }
    }

    @Test func aSideloadReplacesTheRunningCatalogVersion() async throws {
        let fixture = try Fixture(identifier: "com.pulkit.edith.dev.sideload-\(UUID().uuidString)")
        defer { fixture.clean() }
        try fixture.install([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        await marketplace.enable(id: "sample")
        #expect(marketplace.sessions.versions["sample"] == "1.0.0")
        let sideload = try fixture.build("1.0.9")
        let package = try await marketplace.sideload(sideload, admit: { _ in })
        #expect(package.version == "1.0.9")
        #expect(marketplace.installed["sample"] == sideload.package)
        #expect(marketplace.sessions.activeIDs == ["sample"])
        #expect(marketplace.sessions.versions["sample"] == "1.0.9")
        #expect(marketplace.error == nil)
        #expect(await fixture.network.count == 0)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func updateAllUpdatesOnlyOutdatedExtensionsIsolatesFailuresAndKeepsEnabledState()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ids = ["sample", "second", "third", "fourth"]
        try fixture.install(ids.map { fixture.package("1.0.0", id: $0) })
        let sample = try fixture.build("1.1.0", id: "sample")
        let second = try fixture.build("1.1.0", id: "second")
        let fourth = fixture.package("1.1.0", id: "fourth")
        let current = fixture.package("1.0.0", id: "third")
        await fixture.network.set(
            data: try fixture.envelope(packages: [sample.package, second.package, current, fourth]))
        let marketplace = try fixture.marketplace(
            ids: ids, workerMode: { _ in "normal" },
            serving: [
                sample.package.downloadURL: sample.archive,
                second.package.downloadURL: second.archive,
            ])
        await marketplace.restoreEnabledExtensions()
        await marketplace.enable(id: "sample")
        await marketplace.checkForUpdates()
        #expect(marketplace.updatableIDs == ["fourth", "sample", "second"])
        let failures = await marketplace.updateAll()
        #expect(Set(failures.keys) == ["fourth"])
        #expect(marketplace.installed["sample"]?.version == "1.1.0")
        #expect(marketplace.installed["second"]?.version == "1.1.0")
        #expect(marketplace.installed["third"]?.version == "1.0.0")
        #expect(marketplace.installed["fourth"]?.version == "1.0.0")
        #expect(marketplace.sessions.versions["sample"] == "1.1.0")
        #expect(marketplace.sessions.activeIDs == ["sample"])
        #expect(marketplace.sessions.enabledIDs == ["sample"])
        #expect(marketplace.updatableIDs == ["fourth"])
        #expect(!marketplace.busy)
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func cliUpdateAllSummarizesUpdatedFailedAndUpToDateExtensions() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ids = ["sample", "second", "third"]
        try fixture.install(ids.map { fixture.package("1.0.0", id: $0) })
        let sample = try fixture.build("1.1.0", id: "sample")
        let current = fixture.package("1.0.0", id: "third")
        let missing = fixture.package("1.1.0", id: "second")
        await fixture.network.set(
            data: try fixture.envelope(packages: [sample.package, missing, current]))
        let marketplace = try fixture.marketplace(
            ids: ids, serving: [sample.package.downloadURL: sample.archive])
        let reply = try await HostCLIGateway(marketplace: marketplace)
            .execute(HostCLIRequest(action: .updateAll))
        let summary = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(summary["updated"] as? [String] == ["sample"])
        #expect(Array((summary["failed"] as? [String: String] ?? [:]).keys) == ["second"])
        #expect(summary["upToDate"] as? [String] == ["third"])
        let parsed = try HostCLICommand.parse(["extensions", "update", "--all", "--json"])
        #expect(parsed == .request(try HostCLIRequest(action: .updateAll)))
    }

    private func report(_ marketplace: HostMarketplace, _ id: String = "sample") async throws
        -> [String: Any]
    {
        let reply = try await HostCLIGateway(marketplace: marketplace)
            .execute(HostCLIRequest(action: .info, id: id))
        return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    @Test func cliReportsAnUninstalledCatalogPackageAsCompatibleAndNotInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        await fixture.network.set(data: try fixture.envelope(packages: [fixture.package("1.0.0")]))
        let marketplace = try fixture.marketplace()
        await marketplace.checkForUpdates()
        let info = try await report(marketplace)
        #expect(info["compatible"] as? Bool == true)
        #expect(info["installed"] as? Bool == false)
        #expect(info["state"] as? String == "notInstalled")
        #expect(info["availableVersion"] as? String == "1.0.0")
    }

    @Test func cliReportsADownloadedButDisabledExtensionAsDisabled() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.install([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        await marketplace.restoreEnabledExtensions()
        var info = try await report(marketplace)
        #expect(info["installed"] as? Bool == true)
        #expect(info["compatible"] as? Bool == true)
        #expect(info["enabled"] as? Bool == false)
        #expect(info["state"] as? String == "disabled")
        await marketplace.enable(id: "sample")
        info = try await report(marketplace)
        #expect(info["state"] as? String == "active")
        await marketplace.disable(id: "sample")
        info = try await report(marketplace)
        #expect(info["state"] as? String == "disabled")
        await marketplace.remove(id: "sample")
        info = try await report(marketplace)
        #expect(info["state"] as? String == "notInstalled")
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func cliInstallEnablesAnInstalledButDisabledExtension() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.install([fixture.package("1.0.0")])
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        await marketplace.restoreEnabledExtensions()
        let gateway = HostCLIGateway(marketplace: marketplace)
        var info = try await report(marketplace)
        #expect(info["state"] as? String == "disabled")
        let reply = try await gateway.execute(HostCLIRequest(action: .install, id: "sample"))
        info = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(info["state"] as? String == "active")
        let again = try await gateway.execute(HostCLIRequest(action: .install, id: "sample"))
        info = try #require(try JSONSerialization.jsonObject(with: again) as? [String: Any])
        #expect(info["state"] as? String == "active")
        #expect(await marketplace.sessions.shutdown())
    }

    @Test func cliReportsADownloadedPackageForAnotherHostAsIncompatible() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.commit([fixture.package("1.0.0", abi: "incompatible")])
        let marketplace = try fixture.marketplace()
        let info = try await report(marketplace)
        #expect(info["installed"] as? Bool == true)
        #expect(info["compatible"] as? Bool == false)
    }

    @Test func removingAnExtensionWhoseSettingsWereViewedCompletesImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let package = fixture.package("1.0.0")
        try fixture.install([package])
        try FileManager.default.createDirectory(
            at: fixture.store.roleBundle(for: package, role: .app),
            withIntermediateDirectories: true)
        let marketplace = try fixture.marketplace(workerMode: { _ in "normal" })
        let manager = HostRemoteSessionManager(marketplace: marketplace)
        let settings = HostExtensionContentRequest(
            extensionID: "sample", location: "settings", section: "extension")
        let session = try HostLocalSession(
            configuration: manager.selectedConfiguration(for: settings), engine: nil,
            marketplace: marketplace)
        #expect(throws: MarketplaceError.packageBusy) {
            try PackageFileLock(url: fixture.store.leaseURL(for: package), exclusive: true)
        }
        let failure = await marketplace.remove(id: "sample")
        #expect(failure == nil)
        #expect(marketplace.pendingRemovalIDs.isEmpty)
        #expect(marketplace.installedVersions["sample"] == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        withExtendedLifetime(session) {}
    }

    @Test func extensionsInstalledTogetherWorkAtOnceAndAfterARelaunchWithoutRestarts() async throws
    {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let ids = ["sample", "second", "third", "fourth"]
        let builds = try ids.map { try fixture.build("1.0.0", id: $0) }
        await fixture.network.set(data: try fixture.envelope(packages: builds.map(\.package)))
        let archives = Dictionary(
            uniqueKeysWithValues: builds.map { ($0.package.downloadURL, $0.archive) })
        let marketplace = try fixture.marketplace(
            ids: ids, workerMode: { _ in "normal" }, serving: archives)
        let gateway = HostCLIGateway(marketplace: marketplace)

        for id in ids {
            let reply = try await gateway.execute(HostCLIRequest(action: .install, id: id))
            let info = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
            #expect(info["state"] as? String == "active")
            #expect(info["running"] as? Bool == true)
        }
        #expect(marketplace.downloadedIDs == Set(ids))
        for id in ids {
            let reply = try await gateway.execute(HostCLIRequest(action: .enable, id: id))
            let info = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
            #expect(info["state"] as? String == "active")
        }
        try await expectEveryExtensionAvailable(ids, marketplace: marketplace, gateway: gateway)
        #expect(marketplace.error == nil)
        #expect(await marketplace.sessions.shutdown(reason: .applicationQuit))

        let relaunched = try fixture.marketplace(
            ids: ids, workerMode: { _ in "normal" }, serving: archives)
        await relaunched.loadCachedCatalog()
        await relaunched.restoreEnabledExtensions()
        try await expectEveryExtensionAvailable(
            ids, marketplace: relaunched, gateway: HostCLIGateway(marketplace: relaunched))
        #expect(await relaunched.sessions.shutdown())
    }

    private func expectEveryExtensionAvailable(
        _ ids: [String], marketplace: HostMarketplace, gateway: HostCLIGateway
    ) async throws {
        let listing = try await gateway.execute(HostCLIRequest(action: .ls))
        let states = try JSONDecoder().decode([HostCLIProviderState].self, from: listing)
        #expect(Set(states.filter(\.available).map(\.id)) == Set(ids))
        #expect(marketplace.surfaceAvailability.activeIDs == Set(ids))
        #expect(marketplace.sessions.activeIDs == Set(ids))
        for id in ids {
            #expect(marketplace.sessions.versions[id] == "1.0.0")
            #expect(marketplace.sessions.processIdentifiers[id] != nil)
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

        init(identifier: String = "com.pulkit.edith.tests.marketplace-\(UUID().uuidString)")
            throws
        {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            identity = try HostIdentity(identifier: identifier, supportDirectory: directory)
            store = ExtensionPackageStore(root: identity.root.appendingPathComponent("Extensions"))
            try FileManager.default.createDirectory(
                at: store.root, withIntermediateDirectories: true)
        }

        func marketplace(
            ids: [String] = ["sample"], workerMode: ((ExtensionPackage) -> String)? = nil,
            serving: [URL: URL] = [:]
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
                    guard let archive = serving[url] else { throw MarketplaceError.downloadFailed }
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "download-\(UUID().uuidString).zip")
                    try FileManager.default.copyItem(at: archive, to: copy)
                    return copy
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

        func build(
            _ version: String, abi: String = HostContract.compatibility, id: String = "sample"
        ) throws
            -> ExtensionSideload
        {
            let output = directory.appendingPathComponent("dist-\(UUID().uuidString)")
            let payload = output.appendingPathComponent("staging/\(id)")
            let runtime = payload.appendingPathComponent("app.bundle/Contents/MacOS/Runtime")
            try FileManager.default.createDirectory(
                at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("local runtime \(version)".utf8).write(to: runtime)
            let placeholder = package(version, abi: abi, id: id)
            try JSONEncoder().encode(ExtensionPayloadManifest(package: placeholder)).write(
                to: payload.appendingPathComponent("package.json"))
            let archive = output.appendingPathComponent("\(id).zip")
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            zip.arguments = [
                "-c",
                "import pathlib,sys,zipfile; root=pathlib.Path(sys.argv[1]); "
                    + "z=zipfile.ZipFile(sys.argv[2],'w'); "
                    + "[z.write(p,p.relative_to(root.parent)) for p in sorted(root.rglob('*')) "
                    + "if p.is_file()]; z.close()",
                payload.path, archive.path,
            ]
            try zip.run()
            zip.waitUntilExit()
            let bytes = try Data(contentsOf: archive)
            let installedBytes = try FileManager.default.subpathsOfDirectory(atPath: payload.path)
                .reduce(Int64(0)) { total, path in
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: payload.appendingPathComponent(path).path)
                    return total
                        + (attributes[.type] as? FileAttributeType == .typeRegular
                            ? (attributes[.size] as? Int64 ?? 0) : 0)
                }
            let record = ExtensionPackage(
                id: id, version: version, hostABI: abi,
                downloadURL: placeholder.downloadURL,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                downloadBytes: Int64(bytes.count), installedBytes: installedBytes)
            try JSONEncoder().encode(record).write(
                to: output.appendingPathComponent("\(id).json"))
            return try ExtensionSideload(path: archive)
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: identity.defaultsSuite)?.removePersistentDomain(
                forName: identity.defaultsSuite)
        }
    }
}
