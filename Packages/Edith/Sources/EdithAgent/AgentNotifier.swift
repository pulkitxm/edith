import EdithKit
import Foundation
import UserNotifications

public final class AgentNotifier: @unchecked Sendable {
    public static let shared = AgentNotifier(
        present: { notification in
            Task {
                do {
                    try await AgentNotificationService.shared.enqueue(notification)
                } catch {
                    AgentLog.logger.error(
                        "notification persistence failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return true
        })

    private let queue = DispatchQueue(label: "com.pulkit.edith.agent.notifications")
    private let present: @Sendable (AgentNotification) -> Bool
    private let relay: @Sendable (AgentNotification) -> Void

    public init(
        present: @escaping @Sendable (AgentNotification) -> Bool = AgentNotifier.presentLocally,
        relay: @escaping @Sendable (AgentNotification) -> Void = { notification in
            IPC.post(IPC.Name.presentNotification, userInfo: notification.userInfo)
        }
    ) {
        self.present = present
        self.relay = relay
    }

    public func send(_ alert: MachineAlert) {
        send(
            AgentNotification(
                identifier: alert.identifier, title: alert.title, body: alert.body))
    }

    public func send(_ notification: AgentNotification) {
        queue.async { [present, relay] in
            guard present(notification) else {
                relay(notification)
                return
            }
        }
    }

    public static let presentLocally: @Sendable (AgentNotification) -> Bool = { notification in
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        center.add(
            UNNotificationRequest(
                identifier: notification.identifier, content: content, trigger: nil)
        ) { error in
            guard let error else { return }
            AgentLog.logger.error(
                "notification failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}
