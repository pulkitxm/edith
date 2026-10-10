import EdithExtensionSupport
import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostWorkflowOnboardingTests {
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

    @Test func explicitStartWithoutExtensionsCompletesAndNeverRemovesExistingUserSelection() {
        let fixture = Fixture()
        defer { fixture.remove() }
        fixture.active = ["usage"]
        let model = fixture.model()
        model.present()
        model.skip()
        model.dismiss()
        #expect(fixture.active == ["usage"])
        #expect(fixture.installs.isEmpty)
        #expect(!model.incomplete)
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
        var failures = Set<String>()
        var ready = true
        var installDelay = Duration.zero
        var refresh: () async throws -> Void = {}
        var restore: () async throws -> HostSettingsBackupResult = {
            throw HostWorkflowFailure("No synthetic backup.")
        }
        init() { defaults = UserDefaults(suiteName: name)! }
        func remove() { defaults.removePersistentDomain(forName: name) }
        func model() -> HostWorkflowOnboardingModel {
            HostWorkflowOnboardingModel(
                entries: [
                    HostExtension(
                        id: "usage", title: "Usage", symbolName: "chart.bar", category: "agents"),
                    HostExtension(
                        id: "herdr", title: "Sessions", symbolName: "terminal", category: "agents"),
                ], defaults: defaults,
                environment: HostWorkflowEnvironment(
                    available: { self.available }, installed: { self.installed },
                    active: { self.active }, refresh: { try await self.refresh() },
                    install: { id in
                        self.installs.append(id)
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
