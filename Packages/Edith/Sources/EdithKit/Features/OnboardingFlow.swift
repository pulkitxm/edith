import EdithCore
import Foundation

public struct OnboardingPermission: Equatable, Sendable {
    public let permission: ExtensionPermission
    public let required: Bool

    public init(permission: ExtensionPermission, required: Bool) {
        self.permission = permission
        self.required = required
    }
}

public enum OnboardingFlow {
    public static let completionKey = "onboardingCompleted"
    public static let iCloudBackupKey = "icloudBackup"
    public static let initialSelectedIDs: Set<String> = []
    public static let initialICloudBackup = true

    public static func shouldShowOnboarding(defaults: UserDefaults = SharedDefaults.store) -> Bool {
        !defaults.bool(forKey: completionKey)
            && defaults.bool(forKey: ExtensionDefaultsMigration.freshInstallKey)
    }

    public static func grantedPermissions(
        defaults: UserDefaults = SharedDefaults.store
    ) -> [ExtensionPermission: Bool] {
        Dictionary(
            uniqueKeysWithValues: ExtensionPermission.allCases.map { permission in
                let granted: Bool
                if let key = permission.grantedDefaultsKey {
                    granted = defaults.bool(forKey: key)
                } else {
                    granted = false
                }
                return (permission, granted)
            })
    }

    public static func missingPermissions(
        selectedIDs: Set<String>,
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        granted: [ExtensionPermission: Bool]
    ) -> [OnboardingPermission] {
        let selectedEntries = entries.filter { selectedIDs.contains($0.id) }
        let required = Set(selectedEntries.flatMap(\.requiredPermissions))
        let missingRequired = ExtensionPermission.allCases.filter {
            required.contains($0) && granted[$0] != true
        }
        return missingRequired.map { OnboardingPermission(permission: $0, required: true) }
    }

    public static func hasOptionalPermissions(
        selectedIDs: Set<String>,
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) -> Bool {
        entries.contains {
            selectedIDs.contains($0.id) && !$0.optionalPermissions.isEmpty
        }
    }

    public static func newlyGrantedCount(
        selectedIDs: Set<String>,
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        baseline: [ExtensionPermission: Bool],
        current: [ExtensionPermission: Bool]
    ) -> Int {
        let permissions = Set(
            entries.filter { selectedIDs.contains($0.id) }.flatMap {
                $0.requiredPermissions + $0.optionalPermissions
            })
        return permissions.filter { baseline[$0] != true && current[$0] == true }.count
    }

    public static func enabledExtensionIDs(
        settings: [String: Any],
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) -> Set<String> {
        Set(entries.filter { settings[$0.defaultsKey] as? Bool == true }.map(\.id))
    }

    public static func cloudBackupSelection(
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) -> Set<String>? {
        let file = AppData.cloudDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            return nil
        }
        return enabledExtensionIDs(settings: dict, entries: entries)
    }

    public static func seenKey(for entry: ExtensionRegistryEntry) -> String {
        "extensionPermissionsSeen.\(entry.id)"
    }

    public static func finish(
        selectedIDs: Set<String>,
        icloudBackup: Bool = initialICloudBackup,
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        defaults: UserDefaults = SharedDefaults.store
    ) {
        for entry in entries where selectedIDs.contains(entry.id) {
            defaults.set(true, forKey: entry.defaultsKey)
            defaults.set(true, forKey: seenKey(for: entry))
        }
        defaults.set(icloudBackup, forKey: iCloudBackupKey)
        defaults.set(true, forKey: completionKey)
    }

    public static func skip(defaults: UserDefaults = SharedDefaults.store) {
        defaults.set(initialICloudBackup, forKey: iCloudBackupKey)
        defaults.set(true, forKey: completionKey)
    }
}
