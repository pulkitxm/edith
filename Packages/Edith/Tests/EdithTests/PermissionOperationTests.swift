import Foundation
import Testing

@testable import EdithKit

@Suite struct PermissionOperationTests {
    final class Driver: @unchecked Sendable {
        var requested: [ExtensionPermission] = []
        var opened: [URL] = []
        var refreshes = 0
        var prompts = 0
        var overviews = 0
    }

    @Test func statusReadsTheInjectedDefaultsAndFiltersAttention() {
        let (center, defaults, driver, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = ExtensionRegistry.entries.first { $0.id == "calendar" }!
        defaults.set(true, forKey: calendar.defaultsKey)
        defaults.set(false, forKey: AppStorageKeys.Permissions.calendarGranted)

        let result = center.status(filter: .attention)

        #expect(result.map(\.permission) == [.calendar])
        #expect(driver.requested.isEmpty)
        #expect(driver.opened.isEmpty)
    }

    @Test func requestDispatchesOnceAndCarriesRelaunchPolicy() throws {
        let (center, defaults, driver, suite) = makeCenter(shouldOpenSettings: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let result = try center.request(.screenRecording)

        #expect(driver.requested == [.screenRecording])
        #expect(driver.opened == [ExtensionPermission.screenRecording.settingsURL!])
        #expect(driver.prompts == 1)
        #expect(result.requested)
        #expect(result.settingsOpened)
        #expect(result.relaunch == .edith)
    }

    @Test func delegatedRequestDoesNotOpenSettingsInTheCallingProcess() throws {
        let (center, defaults, driver, suite) = makeCenter(shouldOpenSettings: false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let result = try center.request(.camera)

        #expect(driver.requested == [.camera])
        #expect(driver.opened.isEmpty)
        #expect(!result.settingsOpened)
    }

    @Test func firstUsePermissionProducesAStableRemediationWithoutSideEffects() {
        let (center, defaults, driver, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let remediation = center.remediation(for: .automation)

        #expect(remediation.action == .firstUse)
        #expect(remediation.settingsURL == nil)
        #expect(remediation.relaunch == .none)
        #expect(driver.requested.isEmpty)
        #expect(driver.opened.isEmpty)
    }

    @Test func bluetoothRemainsFirstUseButHasASettingsDestination() throws {
        let (center, defaults, driver, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let remediation = center.remediation(for: .bluetooth)
        let settings = try center.openSettings(for: .bluetooth)

        #expect(remediation.action == .firstUse)
        #expect(remediation.settingsURL == ExtensionPermission.bluetooth.settingsURL)
        #expect(settings.opened)
        #expect(driver.opened == [ExtensionPermission.bluetooth.settingsURL!])
        #expect(driver.requested.isEmpty)
    }

    @Test func firstUsePermissionCannotBeRequestedOrOpened() {
        let (center, defaults, driver, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(throws: PermissionOperationError.firstUse(.automation)) {
            try center.request(.automation)
        }
        #expect(throws: PermissionOperationError.noSettings(.automation)) {
            try center.openSettings(for: .automation)
        }
        #expect(driver.requested.isEmpty)
        #expect(driver.opened.isEmpty)
    }

    @Test func onboardingDecisionUsesTheSamePermissionStateAsStatus() {
        let (center, defaults, _, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let decision = center.onboardingDecision(selectedIDs: ["calendar", "notchShelf"])

        #expect(decision.items.map(\.permission) == [.calendar])
        #expect(decision.hasOptionalPermissions)
    }

    @Test func refreshUsesTheDriverAndReturnsTheMirror() {
        let (center, defaults, driver, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Permissions.cameraGranted)

        let result = center.refresh()

        #expect(driver.refreshes == 1)
        #expect(result.first { $0.permission == .camera }?.isGranted == true)
    }

    @Test func permissionOverviewUsesTheInjectedNavigation() {
        let (center, defaults, driver, suite) = makeCenter()
        defer { defaults.removePersistentDomain(forName: suite) }

        let opened = center.openPermissionOverview()

        #expect(opened)
        #expect(driver.overviews == 1)
        #expect(driver.requested.isEmpty)
    }

    @Test func descriptorsAreUniqueAndRoutable() {
        let descriptors = PermissionOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
    }

    @Test func permissionSurfacesRouteThroughTheSharedOperationLayer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let paths = [
            "Edith/Features/Settings/Views/PermissionsPane.swift",
            "Edith/Features/Onboarding/Views/OnboardingView.swift",
            "Edith/Features/Settings/Views/ExtensionsPane.swift",
            "Edith/Features/Settings/Views/ClipboardRows.swift",
            "Edith/Features/Pages/Views/HomePageView.swift",
            "EdithHelper/Features/Settings/Models/PermissionsModel.swift",
            "EdithHelper/Features/System/ViewModels/SystemStore.swift",
            "EdithHelper/Features/NotchShelf/Views/NotchCameraTab.swift",
            "EdithHelper/Features/Usage/Services/LimitNotifier.swift",
        ]
        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(
                source.contains("MainPermissionOperations")
                    || source.contains("PermissionOperationCenter")
                    || source.contains("PermissionsModel.shared"),
                "\(path) bypasses the permission operation layer")
        }
    }

    private func makeCenter(
        shouldOpenSettings: Bool = false
    ) -> (PermissionOperationCenter, UserDefaults, Driver, String) {
        let suite = "PermissionOperationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let driver = Driver()
        let environment = PermissionOperationEnvironment(
            defaults: defaults,
            requestPermission: { permission in
                driver.requested.append(permission)
                return shouldOpenSettings
            },
            refreshStatus: { driver.refreshes += 1 },
            openSettings: { url in
                driver.opened.append(url)
                return true
            },
            openPermissionOverview: {
                driver.overviews += 1
                return true
            },
            recordPrompt: { driver.prompts += 1 })
        return (PermissionOperationCenter(environment: environment), defaults, driver, suite)
    }
}
