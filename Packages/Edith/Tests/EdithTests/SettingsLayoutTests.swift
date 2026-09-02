import Foundation
import Testing
@testable import Edith
import EdithKit

@Suite struct SettingsLayoutTests {
    @Test func settingsUsesPrimaryNavigationAndFullWidthContent() throws {
        let settingsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/GeneralPane.swift")
        let navigationURL =
            settingsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Navigation/MainNavigationView.swift")
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        let navigation = try String(contentsOf: navigationURL, encoding: .utf8)

        #expect(navigation.contains("NavigationCatalog.rows()"))
        #expect(navigation.contains("SidebarSectionRow"))
        #expect(navigation.contains("CollapsibleSidebarLayout"))
        #expect(navigation.contains(".clipped()"))
        #expect(navigation.contains("Button(action: disclosureAction)"))
        #expect(navigation.contains("rowHovered && !selected"))
        #expect(navigation.contains("if disclosureExpanded != nil"))
        #expect(!navigation.contains("SidebarDisclosureInteraction"))
        #expect(navigation.contains(".zIndex(1)"))
        #expect(!navigation.contains(".move(edge: .top).combined(with: .opacity)"))
        #expect(navigation.contains("rotationEffect(.degrees(expanded ? 90 : 0))"))
        #expect(!navigation.contains("SettingsSidebarRow"))
        #expect(!navigation.contains("AppMaintenanceSidebarRow"))

        let settingsPage = try #require(NavigationCatalog.byID["settings"])
        let maintenancePage = try #require(NavigationCatalog.byID["appMaintenance"])
        #expect(settingsPage.children.map(\.id) == SettingsPane.Tab.allCases.map(\.rawValue))
        #expect(
            maintenancePage.children.map(\.id)
                == AppMaintenanceSection.allCases.map(\.rawValue))
        #expect(settingsPage.expansionKey == AppStorageKeys.General.settingsCategoriesExpanded)
        #expect(
            maintenancePage.expansionKey == AppStorageKeys.AppMaintenance.categoriesExpanded)
        #expect(!settingsPage.detachable)

        #expect(settings.contains(".pickerStyle(.menu)"))
        #expect(!settings.contains(".pickerStyle(.segmented)"))
        #expect(!settings.contains("List(selection: tab)"))
        #expect(settings.contains("case .permissions: .infinity"))
        #expect(settings.contains("UIScale.pt(1180)"))
        #expect(settings.contains("alignment: .topLeading"))
    }

    @Test func everyCategoryHasAnIconAndSummary() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/GeneralPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for category in ["general", "permissions", "shortcuts", "terminal", "icloud", "updates"] {
            #expect(source.contains("case .\(category): return"))
        }
        #expect(source.contains("tab.wrappedValue.summary"))
    }

    @Test func appMaintenanceUsesTheSameMenuNavigationPattern() throws {
        let maintenanceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/Edith/Features/AppMaintenance/AppMaintenanceView.swift")
        let maintenance = try String(contentsOf: maintenanceURL, encoding: .utf8)

        #expect(maintenance.contains("PageHeader("))
        #expect(maintenance.contains("ForEach(AppMaintenanceSection.allCases"))
        #expect(maintenance.contains(".pickerStyle(.menu)"))
        #expect(maintenance.contains("App Maintenance section"))
        #expect(maintenance.contains("theme.opacity(0.2)"))
        #expect(!maintenance.contains(".pickerStyle(.segmented)"))
    }

    @MainActor
    @Test func appMaintenanceFocusIsIndependentFromCheckedUpdates() {
        let dia = updateItem(id: "dia", name: "Dia")
        let telegram = updateItem(id: "telegram", name: "Telegram")
        let model = AppMaintenanceModel()
        model.updates = [dia, telegram]
        model.selectedUpdateIDs = [dia.id, telegram.id]

        model.focusedUpdateID = telegram.id

        #expect(model.focusedUpdate?.id == telegram.id)
        #expect(model.selectedUpdateIDs == [dia.id, telegram.id])
    }

    @Test func permissionCardsUseTheAvailableWidthAdaptively() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Settings/Views/PermissionsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("LazyVGrid(columns: columns"))
        #expect(source.contains(".adaptive(minimum:"))
        #expect(source.contains("maxWidth: .infinity"))
    }

    @Test func disclosureHeightTracksAndClampsAnimationProgress() {
        #expect(SidebarDisclosureGeometry.controlSlotWidth == 28)
        #expect(SidebarDisclosureGeometry.visibleHeight(contentHeight: 180, progress: 0) == 0)
        #expect(SidebarDisclosureGeometry.visibleHeight(contentHeight: 180, progress: 0.5) == 90)
        #expect(SidebarDisclosureGeometry.visibleHeight(contentHeight: 180, progress: 1) == 180)
        #expect(SidebarDisclosureGeometry.visibleHeight(contentHeight: 180, progress: -0.2) == 0)
        #expect(SidebarDisclosureGeometry.visibleHeight(contentHeight: 180, progress: 1.2) == 180)
    }

    private func updateItem(id: String, name: String) -> AppUpdateItem {
        AppUpdateItem(
            id: id, name: name, source: .sparkle, currentVersion: "1.0",
            availableVersion: "2.0", confidence: .high, checkedAt: .distantPast,
            action: .openUpdater, executablePath: "/usr/bin/open", arguments: [])
    }

}
