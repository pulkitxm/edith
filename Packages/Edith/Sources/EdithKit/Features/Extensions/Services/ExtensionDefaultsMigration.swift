import Foundation

public enum ExtensionDefaultsMigration {
    public static let markerKey = "extensionDefaultsMigrated"
    public static let freshInstallKey = "extensionDefaultsFreshInstall"
    public static let registryVersionKey = "registryVersion"
    public static let registryVersion = 2

    @discardableResult
    public static func migrate(
        defaults: UserDefaults = SharedDefaults.store,
        markerKey: String = ExtensionDefaultsMigration.markerKey
    ) -> Bool {
        let freshInstall = migrateAbilityDefaults(defaults: defaults, markerKey: markerKey)
        migrateRegistry(defaults: defaults)
        return freshInstall
    }

    private static func migrateAbilityDefaults(
        defaults: UserDefaults, markerKey: String
    ) -> Bool {
        if defaults.object(forKey: markerKey) != nil {
            if let wasFreshInstall = defaults.object(forKey: freshInstallKey) as? Bool {
                return wasFreshInstall
            }
            defaults.set(false, forKey: freshInstallKey)
            if defaults.object(forKey: OnboardingFlow.completionKey) == nil {
                defaults.set(true, forKey: OnboardingFlow.completionKey)
            }
            return false
        }
        let hasPriorInstall =
            defaults.object(forKey: "hasPromptedPermissions") != nil
            || ExtensionRegistry.entries.contains {
                defaults.object(forKey: $0.defaultsKey) != nil
            }
        if hasPriorInstall {
            for entry in ExtensionRegistry.entries {
                let value =
                    defaults.object(forKey: entry.defaultsKey) as? Bool
                    ?? legacyDefaults[entry.defaultsKey, default: false]
                defaults.set(value, forKey: entry.defaultsKey)
            }
            defaults.set(true, forKey: OnboardingFlow.completionKey)
        }
        defaults.set(!hasPriorInstall, forKey: freshInstallKey)
        defaults.set(true, forKey: markerKey)
        return !hasPriorInstall
    }

    public static func migrateRegistry(defaults: UserDefaults = SharedDefaults.store) {
        guard defaults.integer(forKey: registryVersionKey) < registryVersion else { return }
        for (key, sources) in seededAbilityKeys where !defaults.bool(forKey: key) {
            guard sources.contains(where: { defaults.bool(forKey: $0) }) else { continue }
            defaults.set(true, forKey: key)
        }
        for suite in SuiteRegistry.suites where !defaults.bool(forKey: suite.defaultsKey) {
            let selected = SuiteRegistry.abilities(in: suite.id).contains {
                defaults.bool(forKey: $0.defaultsKey)
            }
            guard selected else { continue }
            defaults.set(true, forKey: suite.defaultsKey)
        }
        defaults.set(registryVersion, forKey: registryVersionKey)
    }

    private static let seededAbilityKeys: [String: [String]] = [
        AppStorageKeys.Homebrew.enabled: [AppStorageKeys.AppMaintenance.enabled],
        AppStorageKeys.Cleaner.enabled: [
            AppStorageKeys.AppMaintenance.enabled, AppStorageKeys.Tabs.systemEnabled,
        ],
        AppStorageKeys.Downloads.enabled: [AppStorageKeys.Tabs.musicEnabled],
    ]

    private static let legacyDefaults: [String: Bool] = [
        AppStorageKeys.Tabs.attentionEnabled: true,
        AppStorageKeys.Tabs.usageEnabled: true,
        AppStorageKeys.Tabs.systemEnabled: true,
        AppStorageKeys.AppMaintenance.enabled: false,
        AppStorageKeys.AppMaintenance.updateAutoRefresh: false,
        AppStorageKeys.AppMaintenance.updateNotifications: true,
        AppStorageKeys.Tabs.companionEnabled: false,
        AppStorageKeys.Tabs.herdrEnabled: false,
        AppStorageKeys.Tabs.quinjetEnabled: false,
        AppStorageKeys.Tabs.seoAuditEnabled: false,
        AppStorageKeys.MenuBar.systemStats: false,
        AppStorageKeys.Mic.muteEnabled: false,
        AppStorageKeys.Tabs.musicEnabled: true,
        AppStorageKeys.Tabs.calendarEnabled: true,
        AppStorageKeys.Notch.shelfEnabled: false,
        AppStorageKeys.Clipboard.enabled: false,
        AppStorageKeys.KeystrokeHighlight.enabled: false,
        FocusDimState.enabledKey: false,
        AppStorageKeys.Presenter.enabled: true,
        AppStorageKeys.ColorPicker.enabled: false,
        LidAwakeState.enabledKey: false,
    ]
}
