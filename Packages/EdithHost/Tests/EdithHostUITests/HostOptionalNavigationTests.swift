import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostOptionalNavigationTests {
    @Test func restoredEnabledSuitesWithNoActiveProvidersReturnHome() throws {
        try withDefaults { defaults in
            for suite in landingProviders.keys {
                defaults.set(true, forKey: key(suite))
                let page = try landing(suite)
                #expect(!HostNavigationCatalog.visible(page, active: [], defaults: defaults))
                #expect(
                    HostNavigationCatalog.resolve(page.id, active: [], defaults: defaults) == "home"
                )
                #expect(defaults.bool(forKey: key(suite)))
            }
            for id in ["home", "extensions", "settings", "about"] {
                #expect(
                    HostNavigationCatalog.visible(
                        HostNavigationCatalog.page(id), active: [], defaults: defaults))
            }
        }
    }

    @Test func eachProviderEnablesItsSuiteWithoutShowingUnavailableSuites() throws {
        try withDefaults { defaults in
            for (suite, providers) in landingProviders {
                for provider in providers {
                    for candidate in landingProviders.keys {
                        let page = try landing(candidate)
                        #expect(
                            HostNavigationCatalog.visible(
                                page, active: [provider], defaults: defaults)
                                == (candidate == suite))
                    }
                }
            }
        }
    }

    @Test func explicitlyDisabledSuitesRemainHiddenWithAnActiveProvider() throws {
        try withDefaults { defaults in
            for (suite, providers) in landingProviders {
                let provider = try #require(providers.sorted().first)
                let page = try landing(suite)
                defaults.set(false, forKey: key(suite))
                #expect(
                    HostNavigationCatalog.resolve(page.id, active: [provider], defaults: defaults)
                        == "home")
                defaults.set(true, forKey: key(suite))
                #expect(
                    HostNavigationCatalog.resolve(page.id, active: [provider], defaults: defaults)
                        == page.id)
            }
        }
    }

    @Test func extensionPagesRequireTheirOwnActiveProvider() throws {
        try withDefaults { defaults in
            for page in HostNavigationCatalog.pages where page.extensionID != nil {
                let provider = try #require(page.extensionID)
                #expect(!HostNavigationCatalog.visible(page, active: [], defaults: defaults))
                #expect(HostNavigationCatalog.visible(page, active: [provider], defaults: defaults))
                #expect(
                    !HostNavigationCatalog.visible(
                        page, active: ["unavailable"], defaults: defaults))
            }
        }
    }

    @Test func maintenanceSelectionUsesOnlyAvailableOriginalSections() {
        #expect(
            HostNavigationCatalog.maintenanceDestination("Updates", active: ["homebrew"])?.id
                == "Packages")
        #expect(
            HostNavigationCatalog.maintenanceDestination("Updates", active: ["cleaner"])?.id
                == "Cleaner")
        #expect(
            HostNavigationCatalog.maintenanceDestination("Remove", active: ["appMaintenance"])?.id
                == "Remove")
        #expect(
            HostNavigationCatalog.maintenanceDestination(
                "History", active: ["appMaintenance", "homebrew"])?.id == "History")
        #expect(
            HostNavigationCatalog.maintenanceDestination(
                "unknown", active: ["appMaintenance", "cleaner"])?.id == "Updates")
        #expect(
            HostNavigationCatalog.maintenanceDestination(
                "Cleaner", active: ["homebrew", "cleaner"])?.id
                == "Cleaner")
        #expect(
            HostNavigationCatalog.maintenanceDestination("Updates", active: ["blitztree"]) == nil)
        #expect(HostNavigationCatalog.maintenanceDestination("Updates", active: []) == nil)
    }

    @Test func disablingAndRestoringLastProviderRetainsSuitePreferences() throws {
        try withDefaults { defaults in
            for (suite, providers) in landingProviders {
                let provider = try #require(providers.sorted().first)
                let page = try landing(suite)
                defaults.set(true, forKey: key(suite))
                #expect(
                    HostNavigationCatalog.resolve(page.id, active: [provider], defaults: defaults)
                        == page.id)
                #expect(
                    HostNavigationCatalog.resolve(page.id, active: [], defaults: defaults) == "home"
                )
                #expect(defaults.bool(forKey: key(suite)))
                #expect(
                    HostNavigationCatalog.resolve(page.id, active: [provider], defaults: defaults)
                        == page.id)
            }
        }
    }

    private var landingProviders: [String: Set<String>] {
        HostNavigationCatalog.suiteProviders.filter { suite, _ in
            HostNavigationCatalog.pages.contains { $0.suite == suite && $0.landing }
        }
    }

    private func key(_ suite: String) -> String { "suite" + suite.capitalized + "Enabled" }

    private func landing(_ suite: String) throws -> HostNavigationPage {
        try #require(HostNavigationCatalog.pages.first { $0.suite == suite && $0.landing })
    }

    private func withDefaults(_ action: (UserDefaults) throws -> Void) throws {
        let suite = "com.pulkit.edith.tests.optional-navigation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try action(defaults)
    }
}
