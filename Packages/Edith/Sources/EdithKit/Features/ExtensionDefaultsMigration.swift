import Foundation

public enum ExtensionDefaultsMigration {
    public static let markerKey = "extensionDefaultsMigrated"
    public static let freshInstallKey = "extensionDefaultsFreshInstall"

    @discardableResult
    public static func migrate(
        defaults: UserDefaults = SharedDefaults.store,
        markerKey: String = ExtensionDefaultsMigration.markerKey
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

    private static let legacyDefaults: [String: Bool] = [
        "tabUsageEnabled": true,
        "tabSystemEnabled": true,
        "tabMachinesEnabled": false,
        "tabCompanionEnabled": false,
        "menuBarSystemStats": false,
        "micMuteEnabled": false,
        "tabMusicEnabled": true,
        "tabCalendarEnabled": true,
        "notchShelfEnabled": false,
        "clipboardEnabled": false,
        "focusDimEnabled": false,
        "presenterEnabled": true,
        "colorPickerEnabled": false,
    ]
}
