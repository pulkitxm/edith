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

    static func request() {
        Task { @MainActor in
            _ = try? await EKEventStore().requestFullAccessToEvents()
            mirror()
        }
        NSWorkspace.shared.open(
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        )
    }
}
