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

    @Test func manifestPagesKeepTheSidebarOrderAndOwners() {
        let pages = HostNavigationCatalog.pages.map {
            [$0.id, $0.parentID ?? "-", $0.extensionID ?? "-", $0.suite ?? "-"].joined(
                separator: ":")
        }
        #expect(
            pages == [
                "home:-:-:-", "agents:-:-:agents", "usage:agents:usage:agents",
                "herdr:agents:herdr:agents", "quinjet:agents:quinjet:agents",
                "companion:agents:companion:agents", "plugins:agents:plugins:agents",
                "machines:agents:machines:agents", "docs:agents:docs:agents",
                "utilities:-:-:utilities",
                "appMaintenance:utilities:appMaintenance:utilities",
                "homebrew:utilities:homebrew:utilities", "cleaner:utilities:cleaner:utilities",
                "blitztree:utilities:blitztree:utilities", "system:utilities:system:utilities",
                "calendar:utilities:calendar:utilities", "desk:-:-:desk", "media:-:-:media",
                "studio:media:studio:media", "timeLapse:media:timeLapse:media",
                "virtualCamera:media:virtualCamera:media", "music:media:music:media",
                "downloads:media:downloads:media", "socialManager:media:socialManager:media",
                "developer:-:-:developer", "database:developer:database:developer",
                "codeStats:developer:codeStats:developer", "seoAudit:developer:seoAudit:developer",
                "latex:developer:latex:developer", "attention:developer:attention:developer",
                "extensions:-:-:-", "settings:-:-:-", "about:-:-:-",
            ])
        #expect(HostNavigationCatalog.page("herdr").icon == .herdr)
        #expect(HostNavigationCatalog.page("socialManager").detachable == false)
        #expect(HostNavigationCatalog.page("studio").detachable)
        #expect(HostNavigationCatalog.page("utilities").sections.isEmpty)
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
            HostNavigationCatalog.resolve("utilities", active: ["bifrost"], defaults: defaults)
                == "home")
        #expect(HostNavigationCatalog.resolve("desk", active: [], defaults: defaults) == "home")
    }
}
