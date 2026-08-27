import Foundation
import UserNotifications

struct LimitReminder: Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
}

final class LimitReminderQueue: @unchecked Sendable {
    typealias Replacement = @Sendable ([LimitReminder]) -> Void

    static let identifiers = ["reminder_session", "reminder_weekly"]

    private let queue: DispatchQueue
    private let replacement: Replacement

    init(
        label: String = "com.pulkit.edith.limit-reminders",
        replacement: Replacement? = nil
    ) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.replacement = replacement ?? Self.systemReplacement
    }

    func submit(_ reminders: [LimitReminder]) {
        queue.async { [replacement] in
            replacement(reminders)
        }
    }

    private static let systemReplacement: Replacement = { reminders in
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components, repeats: false)
            center.add(
                UNNotificationRequest(
                    identifier: reminder.identifier, content: content, trigger: trigger)
            ) { error in
                if let error {
                    NSLog(
                        "Edith notifications: reminder failed (%@): %@",
                        reminder.identifier, error.localizedDescription)
                }
            }
        }
    }
}
