import EdithHostCore
import ExtensionMarketplace
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostLegacyMigrationTests {
    private let ids: Set<String> = [
        "usage", "herdr", "music", "lidAwake", "keepAwake", "docs", "terminal", "machines", "jev",
        "studio",
    ]

    @Test func upgraderSelectionIsRestoredForReviewOnce() {
        let suite = Suite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "extensionDefaultsMigrated")
        suite.defaults.set(3, forKey: "registryVersion")
        suite.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
        suite.defaults.set(true, forKey: "tabUsageEnabled")
        suite.defaults.set(true, forKey: "tabMusicEnabled")
        suite.defaults.set(false, forKey: "tabHerdrEnabled")
        suite.defaults.set(false, forKey: "lidAwakeEnabled")
        suite.defaults.set(true, forKey: "lidAwakeActive")
        let selection = HostLegacyMigration.migrate(
            defaults: suite.defaults, extensionIDs: ids, downloadedIDs: [])
        #expect(
            selection == ["usage", "music", "lidAwake", "docs", "terminal", "machines", "jev"])
        #expect(
            suite.defaults.stringArray(forKey: HostSettingsCatalog.workflowSelectionKey)
                == selection?.sorted())
        #expect(suite.defaults.bool(forKey: HostSettingsCatalog.onboardingReviewPendingKey))
        #expect(
            HostLegacyMigration.migrate(
                defaults: suite.defaults, extensionIDs: ids, downloadedIDs: []) == nil)

        let model = suite.model(ids: ids)
        #expect(model.incomplete)
        model.present()
        #expect(model.stage == .review)
        #expect(model.workflow == .custom)
        #expect(model.selected == selection)
        model.dismiss()
        #expect(!model.incomplete)
    }

    @Test func freshInstallIsLeftToTheNormalOnboarding() {
        let suite = Suite()
        defer { suite.remove() }
        #expect(
            HostLegacyMigration.migrate(
                defaults: suite.defaults, extensionIDs: ids, downloadedIDs: []) == nil)
        #expect(suite.defaults.bool(forKey: HostLegacyMigration.completedKey))
        #expect(suite.defaults.object(forKey: HostSettingsCatalog.workflowSelectionKey) == nil)
        #expect(!suite.defaults.bool(forKey: HostSettingsCatalog.onboardingReviewPendingKey))
    }

    @Test func upgraderWhoAlreadyDownloadedExtensionsIsNotPromptedAgain() {
        let suite = Suite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "extensionDefaultsMigrated")
        suite.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
        suite.defaults.set(true, forKey: "tabUsageEnabled")
        #expect(
            HostLegacyMigration.migrate(
                defaults: suite.defaults, extensionIDs: ids, downloadedIDs: ["usage"]) == nil)
        #expect(!suite.defaults.bool(forKey: HostSettingsCatalog.onboardingReviewPendingKey))
        #expect(!suite.model(ids: ids).incomplete)
    }

    @Test func upgraderWithNoLegacyAbilitiesStillSeesOnboarding() {
        let suite = Suite()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: "extensionDefaultsMigrated")
        suite.defaults.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
        let selection = HostLegacyMigration.migrate(
            defaults: suite.defaults, extensionIDs: ["usage"], downloadedIDs: [])
        #expect(selection == [])
        let model = suite.model(ids: ["usage"])
        #expect(model.incomplete)
        model.present()
        #expect(model.stage == .workflows)
    }

    @Test func everyLegacyAbilityMapsToAShippingExtension() throws {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/manifest.json")
        let entries = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        let shipping = Set(entries.compactMap { $0["id"] as? String })
        let legacy = Set(HostLegacyMigration.abilityKeys.keys).union(
            HostLegacyMigration.alwaysAvailableIDs)
        #expect(legacy == shipping)
    }

    @MainActor private final class Suite {
        let name = "com.pulkit.edith.tests.legacy.\(UUID().uuidString)"
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name)! }
        func remove() { defaults.removePersistentDomain(forName: name) }
        func model(ids: Set<String>) -> HostWorkflowOnboardingModel {
            HostWorkflowOnboardingModel(
                entries: ids.sorted().map {
                    HostExtension(id: $0, title: $0, symbolName: "square", category: "agents")
                }, defaults: defaults,
                environment: HostWorkflowEnvironment(
                    available: { [:] }, installed: { [] }, active: { [] }, refresh: {},
                    install: { _, _ in }, restore: { throw HostWorkflowFailure("Unavailable.") },
                    changed: {}))
        }
    }
}
