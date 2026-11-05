import EdithHostCore
import Foundation

struct HostOnboardingPermission: Identifiable, Equatable {
    let permission: HostPermission
    let requiredBy: [HostExtension]
    let optionalFor: [HostExtension]
    let isGranted: Bool

    var id: String { permission.rawValue }
    var isRequired: Bool { !requiredBy.isEmpty }
    var asksOnFirstUse: Bool { permission.grantsOnFirstUse }
    var canDefer: Bool { !isRequired }
    var needsRelaunch: Bool { permission.needsRelaunch }
    var users: [HostExtension] { requiredBy + optionalFor }
}

enum HostOnboardingPermissionPlan {
    static func items(
        selected: [HostExtension], granted: [HostPermission: Bool]
    ) -> [HostOnboardingPermission] {
        let order = Dictionary(
            uniqueKeysWithValues: HostPermission.allCases.enumerated().map { ($1, $0) })
        return HostPermission.allCases.compactMap { permission -> HostOnboardingPermission? in
            let required = selected.filter { $0.requiredPermissions.contains(permission) }
            let optional = selected.filter {
                $0.optionalPermissions.contains(permission) && !required.contains($0)
            }
            guard !required.isEmpty || !optional.isEmpty else { return nil }
            return HostOnboardingPermission(
                permission: permission, requiredBy: required, optionalFor: optional,
                isGranted: granted[permission] ?? false)
        }
        .sorted { left, right in
            let l = rank(left), r = rank(right)
            return l == r ? order[left.permission]! < order[right.permission]! : l < r
        }
    }

    static func current(
        _ items: [HostOnboardingPermission], deferred: Set<HostPermission>
    ) -> HostPermission? {
        items.first {
            !$0.isGranted && !$0.asksOnFirstUse && !deferred.contains($0.permission)
        }?.permission
    }

    static func relaunchBatch(
        _ items: [HostOnboardingPermission], awaiting: Set<HostPermission>
    ) -> [HostPermission] {
        items.filter { awaiting.contains($0.permission) && !$0.isGranted }.map(\.permission)
    }

    static func blockingRequired(
        _ items: [HostOnboardingPermission]
    ) -> [HostOnboardingPermission] {
        items.filter { $0.isRequired && !$0.isGranted && !$0.asksOnFirstUse }
    }

    private static func rank(_ item: HostOnboardingPermission) -> Int {
        (item.needsRelaunch ? 2 : 0) + (item.isRequired ? 0 : 1)
    }
}
