import Foundation
import UserNotifications

struct NotificationReplacement: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let failureContext: String
}

final class NotificationReplacementQueue: @unchecked Sendable {
    typealias Replacement = @Sendable (NotificationReplacement) -> Void

    static let shared = NotificationReplacementQueue()

    private let queue: DispatchQueue
    private let replacement: Replacement

    init(
        label: String = "com.pulkit.edith.notification-replacements",
        replacement: Replacement? = nil
    ) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.replacement = replacement ?? Self.systemReplacement
    }

    func submit(_ notification: NotificationReplacement) {
        queue.async { [replacement] in
            replacement(notification)
        }
    }

    private static let systemReplacement: Replacement = { notification in
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        center.removeDeliveredNotifications(withIdentifiers: [notification.identifier])
        center.add(
            UNNotificationRequest(
                identifier: notification.identifier, content: content, trigger: nil)
        ) { error in
            if let error {
                NSLog("%@: %@", notification.failureContext, error.localizedDescription)
            }
        }
    }
}
