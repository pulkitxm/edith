import AppKit

enum AccessibilityAnnouncement {
    static func post(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ])
    }
}
