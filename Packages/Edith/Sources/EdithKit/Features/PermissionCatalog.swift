import Foundation

public struct PermissionUsage: Identifiable, Equatable, Sendable {
    public let permission: ExtensionPermission
    public let requiredBy: [ExtensionRegistryEntry]
    public let optionalFor: [ExtensionRegistryEntry]
    public let enabledRequiredBy: [ExtensionRegistryEntry]
    public let enabledOptionalFor: [ExtensionRegistryEntry]
    public let isGranted: Bool

    public var id: String { permission.rawValue }
    public var grantsOnFirstUse: Bool { permission.grantRequest == nil }
    public var users: [ExtensionRegistryEntry] { requiredBy + optionalFor }
    public var enabledUsers: [ExtensionRegistryEntry] { enabledRequiredBy + enabledOptionalFor }
    public var isUsedByEnabledExtension: Bool { !enabledUsers.isEmpty }
    public var blocksEnabledExtension: Bool { !isGranted && !enabledRequiredBy.isEmpty }
}

public enum PermissionFilter: String, CaseIterable, Hashable, Sendable {
    case mine = "My extensions"
    case all = "All permissions"
    case attention = "Needs attention"
}

public enum PermissionCatalog {
    public static func usages(
        entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries,
        enabledKeys: Set<String>,
        granted: [ExtensionPermission: Bool]
    ) -> [PermissionUsage] {
        ExtensionPermission.allCases.map { permission in
            let requiredBy = entries.filter { $0.requiredPermissions.contains(permission) }
            let optionalFor = entries.filter { $0.optionalPermissions.contains(permission) }
            return PermissionUsage(
                permission: permission,
                requiredBy: requiredBy,
                optionalFor: optionalFor,
                enabledRequiredBy: requiredBy.filter { enabledKeys.contains($0.defaultsKey) },
                enabledOptionalFor: optionalFor.filter { enabledKeys.contains($0.defaultsKey) },
                isGranted: granted[permission] ?? false)
        }
    }

    public static func filter(
        _ usages: [PermissionUsage], by filter: PermissionFilter
    ) -> [PermissionUsage] {
        usages.filter { usage in
            switch filter {
            case .all: true
            case .mine: usage.isUsedByEnabledExtension
            case .attention: usage.blocksEnabledExtension
            }
        }
    }

    public static func needsAttention(_ usages: [PermissionUsage]) -> Bool {
        usages.contains { $0.blocksEnabledExtension }
    }

    public static func grantable(_ usages: [PermissionUsage]) -> [PermissionUsage] {
        usages.filter { !$0.isGranted && !$0.grantsOnFirstUse && $0.isUsedByEnabledExtension }
    }

    public static func grantedCount(_ usages: [PermissionUsage]) -> Int {
        usages.filter(\.isGranted).count
    }
}
