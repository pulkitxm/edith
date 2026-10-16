import EdithHostCore
import Foundation

enum HostLegacyMigration {
    static let completedKey = "legacyExtensionMigrationCompleted"
    static let markerKeys = ["extensionDefaultsMigrated", "registryVersion"]
    static let lidAwakeActiveKey = "lidAwakeActive"
    static let alwaysAvailableIDs: Set<String> = ["docs", "jev", "machines", "terminal"]
    static let abilityKeys: [String: String] = [
        "appMaintenance": "appMaintenanceEnabled",
        "attention": "tabAttentionEnabled",
        "audioMixer": "notchAudioMixerEnabled",
        "bifrost": "bifrostEnabled",
        "blitztree": "tabBlitzTreeEnabled",
        "calendar": "tabCalendarEnabled",
        "cleaner": "cleanerEnabled",
        "clipboard": "clipboardEnabled",
        "codeStats": "tabCodeStatsEnabled",
        "colorPicker": "colorPickerEnabled",
        "companion": "tabCompanionEnabled",
        "database": "tabDatabaseEnabled",
        "downloads": "downloadsEnabled",
        "emoji": "emojiEnabled",
        "focusDim": "focusDimEnabled",
        "herdr": "tabHerdrEnabled",
        "homebrew": "homebrewEnabled",
        "keepAwake": "keepAwakeEnabled",
        "keystrokeHighlight": "keystrokeHighlightEnabled",
        "latex": "tabLaTeXEnabled",
        "lidAwake": "lidAwakeEnabled",
        "micMute": "micMuteEnabled",
        "music": "tabMusicEnabled",
        "notchShelf": "notchShelfEnabled",
        "plugins": "tabPluginsEnabled",
        "presenter": "presenterEnabled",
        "quinjet": "tabQuinjetEnabled",
        "seoAudit": "tabSEOAuditEnabled",
        "studio": "tabStudioEnabled",
        "system": "tabSystemEnabled",
        "systemStats": "menuBarSystemStats",
        "timeLapse": "tabTimeLapseEnabled",
        "usage": "tabUsageEnabled",
        "virtualCamera": "virtualCameraEnabled",
        "windowSweaters": "windowSweatersEnabled",
    ]

    static let terminalPreferenceKeys: [String: String] = [
        "herdrTerminalFontSize": "terminalFontSize",
        "herdrTerminalConfirmClose": "terminalConfirmClose",
        "herdrTerminalStartupCommand": "terminalStartupCommand",
    ]

    static func migrateTerminalPreferences(_ defaults: UserDefaults) {
        for (old, new) in terminalPreferenceKeys {
            guard defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old)
            else { continue }
            defaults.set(value, forKey: new)
        }
    }

    @discardableResult
    static func migrate(
        defaults: UserDefaults, extensionIDs: Set<String>, downloadedIDs: Set<String>
    ) -> Set<String>? {
        guard !defaults.bool(forKey: completedKey) else { return nil }
        defaults.set(true, forKey: completedKey)
        let legacy = markerKeys.contains(where: { defaults.object(forKey: $0) != nil })
        if legacy { migrateTerminalPreferences(defaults) }
        guard downloadedIDs.isEmpty, legacy else { return nil }
        var selection = alwaysAvailableIDs.union(
            abilityKeys.filter { defaults.bool(forKey: $0.value) }.keys)
        if defaults.bool(forKey: lidAwakeActiveKey) { selection.insert("lidAwake") }
        selection.formIntersection(extensionIDs)
        defaults.set(HostWorkflow.custom.rawValue, forKey: HostSettingsCatalog.workflowKey)
        defaults.set(selection.sorted(), forKey: HostSettingsCatalog.workflowSelectionKey)
        defaults.set(true, forKey: HostSettingsCatalog.onboardingReviewPendingKey)
        defaults.synchronize()
        return selection
    }
}
