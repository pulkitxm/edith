import Foundation
import UserNotifications

enum HostNotifications {
    static let updateReadyIdentifier = "update_ready"

    static func updateReadyTitle(_ version: String) -> String { "Edith \(version) is ready" }

    static let updateReadyBody = "Quit and reopen Edith to finish updating."

    static func postUpdateReady(
        version: String, center: UNUserNotificationCenter = .current()
    ) {
        let content = UNMutableNotificationContent()
        content.title = updateReadyTitle(version)
        content.body = updateReadyBody
        content.sound = .default
        center.removePendingNotificationRequests(withIdentifiers: [updateReadyIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [updateReadyIdentifier])
        center.add(
            UNNotificationRequest(
                identifier: updateReadyIdentifier, content: content, trigger: nil)
        ) { error in
            if let error {
                NSLog("Edith notifications: update nudge failed: %@", error.localizedDescription)
            }
        }
    }

    static func sendTest(center: UNUserNotificationCenter = .current()) async -> String {
        var status = await center.notificationSettings().authorizationStatus
        switch status {
        case .denied:
            return "Blocked - enable Edith in System Settings > Notifications"
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional else {
                return "Permission not granted"
            }
        default:
            break
        }
        let id = "test_\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = "Hey, you're set"
        content.body = "If you see this, notifications work"
        content.sound = .default
        do {
            try await center.add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let delivered = await center.deliveredNotifications().contains {
            $0.request.identifier == id
        }
        return delivered ? "Delivered" : "Sent but not delivered - check Focus / System Settings"
    }
}
