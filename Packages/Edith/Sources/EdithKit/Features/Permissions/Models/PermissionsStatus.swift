import Foundation

public enum PermissionsStatus {
    public static var current: Bool {
        current(defaults: SharedDefaults.store)
    }

    public static func current(defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: AppStorageKeys.Tabs.usageEnabled),
            defaults.bool(forKey: AppStorageKeys.Notify.master),
            !defaults.bool(forKey: AppStorageKeys.Permissions.notificationsGranted)
        {
            return true
        }
        return PermissionCatalog.needsAttention(usages(defaults: defaults))
    }

    public static var granted: [ExtensionPermission: Bool] {
        granted(defaults: SharedDefaults.store)
    }

    public static func granted(defaults: UserDefaults) -> [ExtensionPermission: Bool] {
        return ExtensionPermission.allCases.reduce(into: [:]) { result, permission in
            guard let key = permission.grantedDefaultsKey else {
                result[permission] = false
                return
            }
            result[permission] = defaults.bool(forKey: key)
        }
    }

    public static var usages: [PermissionUsage] {
        usages(defaults: SharedDefaults.store)
    }

    public static func usages(defaults: UserDefaults) -> [PermissionUsage] {
        let enabledKeys = Set(
            ExtensionRegistry.entries.map(\.defaultsKey).filter { defaults.bool(forKey: $0) })
        return PermissionCatalog.usages(
            enabledKeys: enabledKeys, granted: granted(defaults: defaults))
    }
}
