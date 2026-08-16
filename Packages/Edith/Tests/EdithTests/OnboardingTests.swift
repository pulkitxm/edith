import Foundation
import Testing

@testable import EdithKit

@Suite struct OnboardingTests {
    @Test func noExtensionsArePreselected() {
        #expect(OnboardingFlow.initialSelectedIDs.isEmpty)
    }

    @Test func enabledExtensionIDsComeFromBackupSettings() {
        let entries = ExtensionRegistry.entries
        let enabled = entries[0]
        let disabled = entries[1]
        let settings: [String: Any] = [
            enabled.defaultsKey: true,
            disabled.defaultsKey: false,
            "unrelatedKey": true,
        ]

        let ids = OnboardingFlow.enabledExtensionIDs(settings: settings, entries: entries)

        #expect(ids == [enabled.id])
    }

    @Test func freshInstallShowsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let freshInstall = ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(freshInstall)
        #expect(defaults.bool(forKey: ExtensionDefaultsMigration.freshInstallKey))
        #expect(OnboardingFlow.shouldShowOnboarding(defaults: defaults))
        #expect(!defaults.bool(forKey: OnboardingFlow.completionKey))
    }

    @Test func priorInstallSkipsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "hasPromptedPermissions")

        let freshInstall = ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(!freshInstall)
        #expect(!defaults.bool(forKey: ExtensionDefaultsMigration.freshInstallKey))
        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(!OnboardingFlow.shouldShowOnboarding(defaults: defaults))
    }

    @Test func existingMigrationMarkerSkipsNewTour() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: ExtensionDefaultsMigration.markerKey)

        let freshInstall = ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(!freshInstall)
        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(!OnboardingFlow.shouldShowOnboarding(defaults: defaults))
    }

    @Test func explicitExtensionToggleSkipsOnboarding() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "clipboardEnabled")

        ExtensionDefaultsMigration.migrate(defaults: defaults)

        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(!OnboardingFlow.shouldShowOnboarding(defaults: defaults))
    }

    @Test func permissionStepAggregatesOnlyMissingRequiredValues() {
        let selectedIDs: Set<String> = [
            "calendar", "presenter", "colorPicker", "system", "clipboard", "usage",
        ]
        let permissions = OnboardingFlow.missingPermissions(
            selectedIDs: selectedIDs,
            granted: [
                .calendar: true,
                .screenRecording: false,
                .accessibility: false,
                .inputMonitoring: false,
                .notifications: false,
            ])

        #expect(
            permissions
                == [OnboardingPermission(permission: .screenRecording, required: true)])
        #expect(OnboardingFlow.hasOptionalPermissions(selectedIDs: selectedIDs))
    }

    @Test func optionalOnlySelectionsSkipPermissionStep() {
        let selectedIDs: Set<String> = ["system", "clipboard", "usage", "notchShelf"]

        #expect(
            OnboardingFlow.missingPermissions(selectedIDs: selectedIDs, granted: [:]).isEmpty)
        #expect(OnboardingFlow.hasOptionalPermissions(selectedIDs: selectedIDs))
    }

    @Test func preexistingPermissionIsNotNewlyGranted() {
        let count = OnboardingFlow.newlyGrantedCount(
            selectedIDs: ["usage"],
            baseline: [.notifications: true],
            current: [.notifications: true])

        #expect(count == 0)
    }

    @Test func permissionGrantedDuringOnboardingIsNewlyGranted() {
        let count = OnboardingFlow.newlyGrantedCount(
            selectedIDs: ["usage"],
            baseline: [.notifications: false],
            current: [.notifications: true])

        #expect(count == 1)
    }

    @Test func unselectedExtensionPermissionIsNotNewlyGranted() {
        let count = OnboardingFlow.newlyGrantedCount(
            selectedIDs: ["usage"],
            baseline: [.screenRecording: false],
            current: [.screenRecording: true])

        #expect(count == 0)
    }

    @Test func skipEnablesNothingButKeepsBackupsOn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OnboardingFlow.skip(defaults: defaults)

        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(defaults.bool(forKey: OnboardingFlow.iCloudBackupKey))
        for entry in ExtensionRegistry.entries {
            #expect(defaults.object(forKey: entry.defaultsKey) == nil)
            #expect(defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) == nil)
        }
    }

    @Test func finishWritesExactlySelectedExtensionKeys() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selectedIDs: Set<String> = ["usage", "notchShelf"]

        OnboardingFlow.finish(selectedIDs: selectedIDs, defaults: defaults)

        #expect(defaults.bool(forKey: OnboardingFlow.completionKey))
        #expect(OnboardingFlow.initialICloudBackup)
        #expect(defaults.object(forKey: OnboardingFlow.iCloudBackupKey) as? Bool == true)
        for entry in ExtensionRegistry.entries {
            if selectedIDs.contains(entry.id) {
                #expect(defaults.object(forKey: entry.defaultsKey) as? Bool == true)
                #expect(
                    defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) as? Bool == true)
            } else {
                #expect(defaults.object(forKey: entry.defaultsKey) == nil)
                #expect(defaults.object(forKey: OnboardingFlow.seenKey(for: entry)) == nil)
            }
        }
    }

    @Test func finishWritesICloudOptIn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OnboardingFlow.finish(selectedIDs: [], icloudBackup: true, defaults: defaults)

        #expect(defaults.object(forKey: OnboardingFlow.iCloudBackupKey) as? Bool == true)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
