import Foundation
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

    @Test func appItemsUseInformationArchitectureOrder() {
        #expect(MainDestination.appItems == [.extensions, .settings, .about])
    }

    @Test func homeItemsUseInformationArchitectureOrder() {
        #expect(
            MainDestination.homeItems == [
                .home, .attention, .dashboard, .herdr, .quinjet, .music, .calendar, .system,
                .appMaintenance, .machines, .companion,
            ])
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
                mainWindowSection: "settings", settingsTab: "terminal")
                == MainNavigationSelection(
                    mainWindowSection: "settings", settingsTab: "terminal"))
        #expect(
            MainNavigationFallback.resolve(
                mainWindowSection: "permissions", settingsTab: "shortcuts")
                == MainNavigationSelection(
                    mainWindowSection: "home", settingsTab: "shortcuts"))
    }

    @Test func everyExtensionBackedUtilityKeepsTheFooterVisible() {
        #expect(
            !SidebarUtilityVisibility(
                system: false, presenter: false, lidAwake: false, keystrokeHighlight: false
            )
            .hasActions)
        #expect(
            SidebarUtilityVisibility(
                system: true, presenter: false, lidAwake: false, keystrokeHighlight: false
            )
            .hasActions)
        #expect(
            SidebarUtilityVisibility(
                system: false, presenter: true, lidAwake: false, keystrokeHighlight: false
            )
            .hasActions)
        #expect(
            SidebarUtilityVisibility(
                system: false, presenter: false, lidAwake: true, keystrokeHighlight: false
            )
            .hasActions)
        #expect(
            SidebarUtilityVisibility(
                system: false, presenter: false, lidAwake: false, keystrokeHighlight: true
            )
            .hasActions)
    }

    @Test func extensionBackedUtilitiesShareOneAnimatedVisibilityState() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Core/Navigation/MainNavigationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("value: sidebarUtilityVisibility"))
        #expect(source.components(separatedBy: ".transition(sidebarUtilityTransition)").count == 5)
    }
}
