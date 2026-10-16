import EdithHostCore
import Foundation

struct HostPermissionUsage: Identifiable, Equatable, Sendable {
    let permission: HostPermission
    let requiredBy: [HostExtension]
    let optionalFor: [HostExtension]
    let enabledRequiredBy: [HostExtension]
    let enabledOptionalFor: [HostExtension]
    let isGranted: Bool

    var id: String { permission.rawValue }
    var grantsOnFirstUse: Bool { permission.grantsOnFirstUse }
    var users: [HostExtension] { requiredBy + optionalFor }
    var enabledUsers: [HostExtension] { enabledRequiredBy + enabledOptionalFor }
    var isUsedByEnabledExtension: Bool { !enabledUsers.isEmpty }
    var blocksEnabledExtension: Bool { !isGranted && !enabledRequiredBy.isEmpty }
}

enum HostPermissionFilter: String, CaseIterable, Hashable, Sendable {
    case mine = "My extensions"
    case all = "All permissions"
    case attention = "Needs attention"
}

enum HostPermissionCatalog {
    static func usages(
        entries: [HostExtension],
        activeIDs: Set<String>,
        granted: [HostPermission: Bool]
    ) -> [HostPermissionUsage] {
        HostPermission.allCases.map { permission in
            let requiredBy = entries.filter { $0.requiredPermissions.contains(permission) }
            let optionalFor = entries.filter { $0.optionalPermissions.contains(permission) }
            return HostPermissionUsage(
                permission: permission,
                requiredBy: requiredBy,
                optionalFor: optionalFor,
                enabledRequiredBy: requiredBy.filter { activeIDs.contains($0.id) },
                enabledOptionalFor: optionalFor.filter { activeIDs.contains($0.id) },
                isGranted: granted[permission] ?? false)
        }
    }

    static func filter(
        _ usages: [HostPermissionUsage], by filter: HostPermissionFilter
    ) -> [HostPermissionUsage] {
        usages.filter { usage in
            switch filter {
            case .all: true
            case .mine: usage.isUsedByEnabledExtension
            case .attention: usage.blocksEnabledExtension
            }
        }
    }

    static func needsAttention(_ usages: [HostPermissionUsage]) -> Bool {
        usages.contains { $0.blocksEnabledExtension }
    }

    static func grantable(_ usages: [HostPermissionUsage]) -> [HostPermissionUsage] {
        usages.filter { !$0.isGranted && !$0.grantsOnFirstUse && $0.isUsedByEnabledExtension }
    }

    static func grantedCount(_ usages: [HostPermissionUsage]) -> Int {
        usages.filter(\.isGranted).count
    }
}

extension HostExtension {
    var requiredPermissions: [HostPermission] {
        switch id {
        case "calendar": [.calendar]
        case "virtualCamera": [.camera]
        case "focusDim", "presenter", "colorPicker", "timeLapse": [.screenRecording]
        case "keystrokeHighlight": [.inputMonitoring]
        default: []
        }
    }
    var optionalPermissions: [HostPermission] {
        switch id {
        case "blitztree": [.fullDisk]
        case "usage", "appMaintenance": [.notifications]
        case "system": [.accessibility, .inputMonitoring]
        case "notchShelf": [.bluetooth, .camera, .automation]
        case "audioMixer": [.applicationAudio]
        case "clipboard", "emoji", "windowSweaters", "bifrost": [.accessibility]
        default: []
        }
    }
}
