import Foundation

public enum PermissionsStatus {
    public static var current: Bool {
        let d = SharedDefaults.store
        func on(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        return needsAttention(
            calendarTab: on("tabCalendarEnabled"), systemTab: on("tabSystemEnabled"),
            notifyMaster: d.bool(forKey: "notifyMaster"),
            calendar: d.bool(forKey: "permCalendarGranted"),
            accessibility: d.bool(forKey: "permAccessibilityGranted"),
            inputMonitoring: d.bool(forKey: "permInputMonitoringGranted"),
            notifications: d.bool(forKey: "permNotificationsGranted"))
    }

    public static func needsAttention(
        calendarTab: Bool, systemTab: Bool, notifyMaster: Bool,
        calendar: Bool, accessibility: Bool, inputMonitoring: Bool, notifications: Bool
    ) -> Bool {
        if calendarTab, !calendar { return true }
        if systemTab, !accessibility || !inputMonitoring { return true }
        if notifyMaster, !notifications { return true }
        return false
    }
}
