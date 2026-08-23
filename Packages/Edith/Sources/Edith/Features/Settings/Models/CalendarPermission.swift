import AppKit
import EdithKit
import EventKit

enum CalendarPermission {
    static var isGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    @discardableResult
    static func mirror() -> Bool {
        let value = isGranted
        let defaults = SharedDefaults.store
        if defaults.object(forKey: AppStorageKeys.Permissions.calendarGranted) as? Bool != value {
            defaults.set(value, forKey: AppStorageKeys.Permissions.calendarGranted)
            IPC.post(IPC.Name.permissionsRefreshed)
        }
        return value
    }

    static func performRequest() {
        Task { @MainActor in
            _ = try? await EKEventStore().requestFullAccessToEvents()
            mirror()
        }
    }
}

@MainActor
enum MainPermissionOperations {
    static var center: PermissionOperationCenter {
        PermissionOperationCenter(
            environment: PermissionOperationEnvironment(
                defaults: SharedDefaults.store,
                requestPermission: { permission in
                    if permission == .calendar {
                        PermissionPromptTracker.record()
                        CalendarPermission.performRequest()
                        return true
                    }
                    guard let request = permission.grantRequest else { return false }
                    IPC.post(request)
                    return false
                },
                refreshStatus: {
                    CalendarPermission.mirror()
                    IPC.post(IPC.Name.requestPermissionsRefresh)
                },
                openSettings: { NSWorkspace.shared.open($0) }))
    }
}
