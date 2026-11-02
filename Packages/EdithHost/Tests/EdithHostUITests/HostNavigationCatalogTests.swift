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
                "home:-:-:-", "agents:-:-:agents", "dashboard:agents:usage:agents",
                "herdr:agents:herdr:agents", "quinjet:agents:quinjet:agents",
                "companion:agents:companion:agents", "plugins:agents:plugins:agents",
                "machines:agents:machines:agents", "docs:agents:docs:agents",
                "system:-:-:utilities", "runningApps:system:system:utilities",
                "blitztree:system:blitztree:utilities", "calendar:system:calendar:utilities",
                "appMaintenance:-:-:utilities", "desk:-:-:desk", "media:-:-:media",
                "studio:media:studio:media", "socialManager:media:socialManager:media",
                "timeLapse:media:timeLapse:media", "downloads:media:downloads:media",
                "music:media:music:media", "virtualCamera:media:virtualCamera:media",
                "data:-:-:developer", "database:data:database:developer",
                "codeStats:data:codeStats:developer", "seoAudit:data:seoAudit:developer",
                "latex:data:latex:developer", "attention:data:attention:developer",
                "extensions:-:-:-", "settings:-:-:-", "about:-:-:-",
            ])
        #expect(HostNavigationCatalog.page("herdr").logoName == "herdr")
        #expect(HostNavigationCatalog.page("socialManager").detachable == false)
        #expect(HostNavigationCatalog.page("studio").detachable)
        #expect(
            HostNavigationCatalog.maintenance.map { $0.id + ":" + ($0.extensionID ?? "-") } == [
                "Updates:appMaintenance", "Packages:homebrew", "Remove:appMaintenance",
                "Cleaner:cleaner", "History:appMaintenance",
            ])
        #expect(
            HostNavigationCatalog.page("appMaintenance").sections
                == HostNavigationCatalog.maintenance)
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
