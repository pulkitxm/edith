import Testing
@testable import Edith

@Suite struct MainDestinationTests {
    @Test func sidebarSectionsAreDisjointAndCoverAllDestinations() {
        let listed = MainDestination.homeItems + MainDestination.appItems
        #expect(Set(listed).count == listed.count)
        #expect(Set(listed) == Set(MainDestination.allCases))
    }

    @Test func rawValuesRoundTrip() {
        for destination in MainDestination.allCases {
            #expect(MainDestination(rawValue: destination.rawValue) == destination)
        }
    }

    @Test func titlesAreUniqueAndNonEmpty() {
        let titles = MainDestination.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test func iconsAreUniqueAndNonEmpty() {
        let icons = MainDestination.allCases.map(\.icon)
        #expect(Set(icons).count == icons.count)
        #expect(icons.allSatisfy { !$0.isEmpty })
    }

    @Test func paperBackgroundOnlyForHomeItems() {
        for destination in MainDestination.homeItems {
            #expect(destination.usesPaperBackground)
        }
        for destination in MainDestination.appItems {
            #expect(!destination.usesPaperBackground)
        }
    }

    @Test func appItemsUseInformationArchitectureOrder() {
        #expect(MainDestination.appItems == [.extensions, .settings, .about])
    }

    @Test func settingsTabsUseInformationArchitectureOrder() {
        #expect(
            SettingsPane.Tab.allCases == [
                .general, .permissions, .shortcuts, .terminal, .icloud, .updates,
            ])
    }

    @Test func resolveKeepsDestinationsAndRejectsLegacyValues() {
        for destination in MainDestination.allCases {
            #expect(MainDestination.resolve(destination.rawValue) == destination)
        }
        #expect(MainDestination.resolve("nonsense") == .home)
        #expect(MainDestination.resolve("usage") == .home)
        #expect(MainDestination.resolve("permissions") == .home)
        #expect(MainDestination.resolve("shortcuts") == .home)
    }

    @Test func legacyNavigationValuesFallBack() {
        #expect(
            MainNavigationFallback.resolve(
                mainWindowSection: "shortcuts", settingsTab: "general")
                == MainNavigationSelection(
                    mainWindowSection: "settings", settingsTab: "shortcuts"))
        #expect(
            MainNavigationFallback.resolve(
                mainWindowSection: "settings", settingsTab: "menubar")
                == MainNavigationSelection(
                    mainWindowSection: "settings", settingsTab: "general"))
        #expect(
            MainNavigationFallback.resolve(
                mainWindowSection: "settings", settingsTab: "usage")
                == MainNavigationSelection(
                    mainWindowSection: "settings", settingsTab: "general"))
        #expect(
            MainNavigationFallback.resolve(
                mainWindowSection: "permissions", settingsTab: "shortcuts")
                == MainNavigationSelection(
                    mainWindowSection: "home", settingsTab: "shortcuts"))
    }
}
