import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite struct HostNavigationCatalogTests {
    @Test func suiteFallbackProvidersMatchEveryBundledCategory() throws {
        let entries = try HostIndex.bundled()
        for (suite, providers) in HostNavigationCatalog.suiteProviders {
            #expect(providers == Set(entries.filter { $0.category == suite }.map(\.id)))
        }
    }

    @Test func restoredBifrostWithoutSuitePreferencesKeepsDeskVisible() throws {
        let suite = "com.pulkit.edith.tests.navigation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.object(forKey: "suiteDeskEnabled") == nil)
        #expect(
            HostNavigationCatalog.resolve("desk", active: ["bifrost"], defaults: defaults) == "desk"
        )
        #expect(
            HostNavigationCatalog.resolve("system", active: ["bifrost"], defaults: defaults)
                == "home")
        #expect(HostNavigationCatalog.resolve("desk", active: [], defaults: defaults) == "home")
    }
}
