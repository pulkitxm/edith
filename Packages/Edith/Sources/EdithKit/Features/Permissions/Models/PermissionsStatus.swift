import Foundation

public enum PermissionsStatus {
    public static var current: Bool {
        let defaults = SharedDefaults.store
        if defaults.bool(forKey: AppStorageKeys.Tabs.usageEnabled),
            defaults.bool(forKey: AppStorageKeys.Notify.master),
            !defaults.bool(forKey: AppStorageKeys.Permissions.notificationsGranted)
        {
            return true
        }
        return PermissionCatalog.needsAttention(usages)
    }

    public static var granted: [ExtensionPermission: Bool] {
        let defaults = SharedDefaults.store
        return ExtensionPermission.allCases.reduce(into: [:]) { result, permission in
            guard let key = permission.grantedDefaultsKey else {
                result[permission] = false
                return
            }
            result[permission] = defaults.bool(forKey: key)
        }
    }

    public static var usages: [PermissionUsage] {
        let defaults = SharedDefaults.store
        let enabledKeys = Set(
            ExtensionRegistry.entries.map(\.defaultsKey).filter { defaults.bool(forKey: $0) })
        return PermissionCatalog.usages(enabledKeys: enabledKeys, granted: granted)
    }
}
