import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostWorkflowOnboardingTests {
    @Test func reviewShowsEachPackagesOwnSignedCatalogVersionAndSizes() {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.available = [
            "usage": package("usage", bytes: 100),
            "herdr": package("herdr", bytes: 300),
        ]
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        let usage = model.reviewMetadata(for: "usage")
        let herdr = model.reviewMetadata(for: "herdr")
        #expect(usage.version == "1.0.0")
        #expect(usage.downloadBytes == 100 && usage.installedBytes == 200)
        #expect(herdr.downloadBytes == 300 && herdr.installedBytes == 600)
        #expect(usage.summary.contains("Catalog version 1.0.0"))
        #expect(usage.summary.contains("download") && usage.summary.contains("unpacked"))
        #expect(!usage.summary.contains("unknown"))
        #expect(usage.summary != herdr.summary)
        #expect(fixture.installs.isEmpty && fixture.active.isEmpty)
    }

    @Test func downloadedPackageWithoutCatalogMetadataDoesNotInventVersionOrZeroSizes() {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.available = [:]
        fixture.installed = ["usage"]
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        let review = model.reviewMetadata(for: "usage")
        #expect(model.visibleEntries.map(\.id) == ["usage"])
        #expect(
            review.version == nil && review.downloadBytes == nil && review.installedBytes == nil)
        #expect(
            review.summary
                == "Catalog version unavailable · Download size unknown · Unpacked size unknown")
        #expect(fixture.installs.isEmpty && fixture.active.isEmpty)
    }

    @Test func reviewKeepsKnownMetadataWhenOnlyOneSizeIsUnavailable() {
        let package = ExtensionPackage(
            id: "usage", version: "2.0.0", hostABI: HostContract.compatibility,
            downloadURL: URL(string: "https://example.invalid/usage.zip")!,
            sha256: String(repeating: "b", count: 64), downloadBytes: 123, installedBytes: 0)
        let review = HostWorkflowPackageReview(package: package)
        #expect(review.version == "2.0.0" && review.downloadBytes == 123)
        #expect(review.installedBytes == nil)
        #expect(review.summary.contains("Catalog version 2.0.0"))
        #expect(review.summary.contains("Unpacked size unknown"))
        #expect(!review.summary.contains("Download size unknown"))
        let missing = HostWorkflowPackageReview(
            package: Self.package("usage", bytes: 0))
        #expect(missing.downloadBytes == nil && missing.installedBytes == nil)
        #expect(missing.version == "1.0.0")
    }

    @Test func staleReviewUpdatesVisibleMetadataBeforeAllowingAnotherInstallAttempt() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.refresh = {
            fixture.available["usage"] = ExtensionPackage(
                id: "usage", version: "2.0.0", hostABI: HostContract.compatibility,
                downloadURL: URL(string: "https://example.invalid/usage-v2.zip")!,
                sha256: String(repeating: "b", count: 64),
                downloadBytes: 500, installedBytes: 1000)
        }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("usage")
        #expect(model.reviewMetadata(for: "usage").version == "1.0.0")
        model.installSelection()
        await finish(model)
        #expect(fixture.installs.isEmpty)
        #expect(model.stage == .review && model.selected == ["usage"])
        #expect(model.reviewMetadata(for: "usage").version == "2.0.0")
        #expect(model.reviewMetadata(for: "usage").downloadBytes == 500)
        #expect(model.reviewMetadata(for: "usage").installedBytes == 1000)
        #expect(model.incomplete)
    }

    @Test func firstShippingCatalogOffersOnlyKeepAwakeWithoutStartingIt() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.available = ["keepAwake": package("keepAwake")]
        let model = fixture.model(entries: try HostIndex.bundled())
        model.present()
        model.choose(.essentials)
        #expect(model.selected == ["keepAwake"])
        #expect(model.visibleEntries.map(\.id) == ["keepAwake"])
        #expect(model.canInstall)
        #expect(model.cost.downloadBytes == 100)
        model.toggle("calendar")
        #expect(model.selected == ["keepAwake"])
        #expect(fixture.installs.isEmpty && fixture.active.isEmpty)
    }

    @Test func unpublishedRestoredSelectionCanBeRemovedWithoutLosingInstalledTools() {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.available = [:]
        fixture.installed = ["usage"]
        fixture.defaults.set(true, forKey: HostWorkflowOnboardingModel.reviewPendingKey)
        fixture.defaults.set(["herdr"], forKey: HostSettingsCatalog.workflowSelectionKey)
        let model = fixture.model()
        model.present()
        #expect(Set(model.visibleEntries.map(\.id)) == ["usage", "herdr"])
        #expect(!model.canInstall)
        model.toggle("herdr")
        #expect(model.selected.isEmpty)
        #expect(model.visibleEntries.map(\.id) == ["usage"])
        #expect(fixture.installed == ["usage"])
        #expect(fixture.installs.isEmpty && fixture.active.isEmpty)
    }

    @Test func selectingWorkflowSuggestsKnownOptionalPackagesWithoutStartingThem() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        #expect(model.selected == ["usage", "herdr"])
        #expect(fixture.installs.isEmpty)
        #expect(fixture.active.isEmpty)
        #expect(!fixture.defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey))
        model.toggle("unknown")
        #expect(model.selected == ["usage", "herdr"])
    }

    @Test func essentialsReviewWithFullCatalogInstallsOnlyExplicitCalendarSelection() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let entries = try HostIndex.bundled()
        #expect(entries.count == 41)
        let suggested = Set(["clipboard", "calendar", "system", "keepAwake", "emoji"])
        fixture.available = Dictionary(uniqueKeysWithValues: suggested.map { ($0, package($0)) })
        let model = fixture.model(entries: entries)
        model.present()
        model.choose(.essentials)
        #expect(model.selected == suggested)
        for id in ["clipboard", "system", "keepAwake", "emoji"] { model.toggle(id) }
        #expect(model.selected == ["calendar"])
        #expect(model.selected.count == 1)
        #expect(model.canInstall)
        #expect(fixture.installs.isEmpty)
        model.installSelection()
        await finish(model)
        #expect(fixture.installs == ["calendar"])
        #expect(fixture.active == ["calendar"])
        #expect(model.stage == .finished)
    }

    @Test func signedSizesCountDependenciesOnceAndExcludeDownloadedCompatiblePackages() {
        let packages = [
            "usage": package("usage", dependencies: ["terminal"]),
            "herdr": package("herdr", dependencies: ["terminal"]), "terminal": package("terminal"),
        ]
        let cost = HostWorkflowCost.calculate(
            selected: ["usage", "herdr"], available: packages, installed: [])
        #expect(cost.downloadBytes == 300)
        #expect(cost.installedBytes == 600)
        #expect(cost.packageIDs == ["usage", "herdr", "terminal"])
        #expect(cost.complete)
        let downloaded = HostWorkflowCost.calculate(
            selected: ["usage", "herdr"], available: packages, installed: ["terminal"])
        #expect(downloaded.downloadBytes == 200)
        #expect(downloaded.installedBytes == 400)
        #expect(downloaded.packageIDs == ["usage", "herdr"])
    }

    @Test func unknownSizesAndOverflowNeverProduceAnApprovedEstimate() {
        let unavailable = HostWorkflowCost.calculate(
            selected: ["usage"], available: [:], installed: [])
        #expect(!unavailable.complete)
        #expect(unavailable.unknownIDs == ["usage"])
        let huge = ["usage": package("usage", bytes: .max), "herdr": package("herdr", bytes: .max)]
        let overflow = HostWorkflowCost.calculate(
            selected: ["usage", "herdr"], available: huge, installed: [])
        #expect(!overflow.complete)
        #expect(overflow.downloadBytes >= 0)
    }

    @Test func restoredCompletionAndSelectionsWaitForReviewWithoutEnablingAnything() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.restore = {
            fixture.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
            return try JSONDecoder().decode(
                HostSettingsBackupResult.self,
                from: Data(
                    "{\"restored\":true,\"exported\":false,\"suggestedExtensionIDs\":[\"usage\",\"unknown\"],\"completedAt\":0}"
                        .utf8))
        }
        let model = fixture.model()
        model.present()
        model.restoreSelection()
        await finish(model)
        #expect(model.selected == ["usage"])
        #expect(model.stage == .review)
        #expect(fixture.installs.isEmpty)
        #expect(fixture.active.isEmpty)
        #expect(model.incomplete)
        #expect(!fixture.defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey))
        #expect(fixture.defaults.bool(forKey: HostWorkflowOnboardingModel.reviewPendingKey))
        model.dismiss()
        #expect(model.presented)
        let reopened = fixture.model()
        #expect(reopened.incomplete)
    }

    @Test func partialFailureRetainsWorkingPackagesAndRetryOnlyFinishesMissingPackages()
        async throws
    {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.failures = ["herdr"]
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        model.installSelection()
        await finish(model)
        #expect(model.states["usage"] == .ready)
        #expect(fixture.active == ["usage"])
        #expect(model.failure != nil)
        #expect(model.incomplete)
        fixture.failures = []
        model.installSelection()
        await finish(model)
        #expect(model.stage == .finished)
        #expect(fixture.active == ["usage", "herdr"])
        #expect(fixture.installs.filter { $0 == "usage" }.count == 1)
        #expect(!model.incomplete)
        model.dismiss()
        #expect(!model.presented)
        #expect(fixture.active == ["usage", "herdr"])
        #expect(fixture.defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey))
    }

    @Test func successfulDownloadWithoutReadyWorkerNeverMarksOnboardingComplete() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.ready = false
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("usage")
        model.installSelection()
        await finish(model)
        #expect(fixture.installed == ["usage"])
        #expect(model.incomplete)
        #expect(model.failure != nil)
        #expect(model.stage == .installing)
    }

    @Test func changedReviewedVersionOrSizeRequiresAnotherReviewBeforeAnyDownload() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.refresh = { fixture.available["usage"] = Self.package("usage", bytes: 500) }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("usage")
        model.installSelection()
        await finish(model)
        #expect(fixture.installs.isEmpty)
        #expect(model.stage == .review)
        #expect(model.incomplete)
        #expect(model.cost.downloadBytes == 500)
    }

    @Test func cancelAndShutdownDrainOwnedInstallerWithoutCompletingOrStartingAnotherPackage()
        async throws
    {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.installDelay = .seconds(30)
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        model.installSelection()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.installs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(fixture.installs.count == 1)
        await model.shutdown()
        #expect(!model.busy)
        #expect(fixture.active.isEmpty)
        #expect(fixture.installed.isEmpty)
        #expect(model.incomplete)
    }

    @Test func pendingReviewSurvivesRestartWithoutEnablingSavedSuggestions() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let original = fixture.model()
        original.present()
        original.choose(.agentic)
        original.toggle("herdr")
        let reopened = fixture.model()
        reopened.present()
        #expect(reopened.stage == .review)
        #expect(reopened.selected == ["usage"])
        #expect(reopened.workflow == .agentic)
        #expect(reopened.incomplete)
        #expect(fixture.installs.isEmpty)
        #expect(fixture.active.isEmpty)
    }

    @Test func explicitBackupChoiceIsPersistedBeforeWorkersStartAndNeverChangesOnSuggestion() async
    {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        model.choose(.custom)
        model.toggle("usage")
        #expect(fixture.defaults.object(forKey: AppStorageKeys.Backup.icloud) == nil)
        model.setICloudBackup(false)
        model.installSelection()
        #expect(!fixture.defaults.bool(forKey: AppStorageKeys.Backup.icloud))
        await finish(model)
        #expect(!fixture.defaults.bool(forKey: AppStorageKeys.Backup.icloud))
        #expect(!model.incomplete)
    }

    @Test func workflowPassesTheFullReviewedPackageToItsOwnedInstaller() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let reviewed = package("usage")
        fixture.available = ["usage": reviewed]
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        model.toggle("herdr")
        model.installSelection()
        await finish(model)
        #expect(fixture.reviewedInstalls == [reviewed])
        #expect(model.stage == .finished)
    }

    @Test func packageChangedInsideDownloadReturnsToReviewBeforeRetry() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.available = ["usage": package("usage")]
        fixture.changedDuringInstall = true
        let model = fixture.model()
        model.present()
        model.choose(.agentic)
        model.toggle("herdr")
        model.installSelection()
        await finish(model)
        #expect(model.stage == .review)
        #expect(model.failure?.contains("Review your selection") == true)
        #expect(fixture.installed.isEmpty && fixture.active.isEmpty)
        #expect(!fixture.defaults.bool(forKey: HostSettingsCatalog.onboardingCompletedKey))
    }

    @Test func emptyFirstLaunchPreservesTheExplicitEmptySetupOption() {
        let fixture = Fixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.present()
        #expect(model.skipTitle == "Start without extensions")
        model.skip()
        #expect(fixture.active.isEmpty)
        #expect(fixture.installs.isEmpty)
    }

    @Test func explicitStartWithoutExtensionsCompletesAndNeverRemovesExistingUserSelection() {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.active = ["usage"]
        let model = fixture.model()
        model.present()
        #expect(model.skipTitle == "Keep current setup")
        model.skip()
        model.dismiss()
        #expect(fixture.active == ["usage"])
        #expect(fixture.installs.isEmpty)
        #expect(!model.incomplete)
    }

    @Test func storageRouteWaitsForCompletedReviewAndUsesExistingSettingsNavigation() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.defaults.set("home", forKey: AppStorageKeys.General.mainWindowSection)
        fixture.defaults.set("general", forKey: AppStorageKeys.General.settingsTab)
        fixture.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
        fixture.restore = {
            fixture.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
            return try JSONDecoder().decode(
                HostSettingsBackupResult.self,
                from: Data(
                    "{\"restored\":true,\"exported\":false,\"suggestedExtensionIDs\":[\"usage\"],\"completedAt\":0}"
                        .utf8))
        }
        let model = fixture.model()
        model.present()
        model.restoreSelection()
        await finish(model)
        model.dismiss()
        #expect(model.presented)
        #expect(model.incomplete)
        model.openStorage()
        #expect(model.presented)
        #expect(fixture.defaults.string(forKey: AppStorageKeys.General.settingsTab) == "general")
        model.installSelection()
        await finish(model)
        #expect(model.stage == .finished)
        model.openStorage()
        #expect(!model.presented)
        #expect(!model.incomplete)
        #expect(fixture.defaults.string(forKey: AppStorageKeys.General.settingsTab) == "storage")
        #expect(
            fixture.defaults.string(forKey: AppStorageKeys.General.mainWindowSection) == "settings")
        #expect(fixture.active == ["usage"])
    }

    private static func package(_ id: String, dependencies: [String] = [], bytes: Int64 = 100)
        -> ExtensionPackage
    {
        ExtensionPackage(
            id: id, version: "1.0.0", hostABI: HostContract.compatibility,
            downloadURL: URL(string: "https://example.invalid/\(id).zip")!,
            sha256: String(repeating: "a", count: 64), downloadBytes: bytes,
            installedBytes: bytes == .max ? 200 : bytes * 2, dependencies: dependencies)
    }
    private func package(_ id: String, dependencies: [String] = [], bytes: Int64 = 100)
        -> ExtensionPackage
    { Self.package(id, dependencies: dependencies, bytes: bytes) }

    private func finish(_ model: HostWorkflowOnboardingModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.busy, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!model.busy)
    }

    @MainActor private final class Fixture {
        let name = "com.pulkit.edith.tests.workflow.\(UUID().uuidString)"
        let defaults: UserDefaults
        var available = [
            "usage": HostWorkflowOnboardingTests.package("usage"),
            "herdr": HostWorkflowOnboardingTests.package("herdr"),
        ]
        var installed = Set<String>()
        var active = Set<String>()
        var installs: [String] = []
        var reviewedInstalls: [ExtensionPackage] = []
        var changedDuringInstall = false
        var failures = Set<String>()
        var ready = true
        var installDelay = Duration.zero
        var refresh: () async throws -> Void = {}
        var restore: () async throws -> HostSettingsBackupResult = {
            throw HostWorkflowFailure("No synthetic backup.")
        }
        init() { defaults = UserDefaults(suiteName: name)! }
        func remove() { defaults.removePersistentDomain(forName: name) }
        func model(entries: [HostExtension]? = nil) -> HostWorkflowOnboardingModel {
            HostWorkflowOnboardingModel(
                entries: entries ?? [
                    HostExtension(
                        id: "usage", title: "Usage", symbolName: "chart.bar", category: "agents"),
                    HostExtension(
                        id: "herdr", title: "Sessions", symbolName: "terminal", category: "agents"),
                ], defaults: defaults,
                environment: HostWorkflowEnvironment(
                    available: { self.available }, installed: { self.installed },
                    active: { self.active }, refresh: { try await self.refresh() },
                    install: { id, expected in
                        if let expected { self.reviewedInstalls.append(expected) }
                        self.installs.append(id)
                        if self.changedDuringInstall { throw HostWorkflowReviewChanged() }
                        if self.installDelay > .zero {
                            try await Task.sleep(for: self.installDelay)
                        }
                        try Task.checkCancellation()
                        if self.failures.contains(id) {
                            throw HostWorkflowFailure("Synthetic installation failed.")
                        }
                        self.installed.insert(id)
                        if self.ready { self.active.insert(id) }
                    }, restore: { try await self.restore() }, changed: {}))
        }
    }
}
