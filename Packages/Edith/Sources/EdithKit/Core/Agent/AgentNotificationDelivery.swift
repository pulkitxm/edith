import Foundation

public enum AgentNotificationOperation {
    public static let pending = "notifications.pending"
    public static let acknowledge = "notifications.acknowledge"
    public static let changed = Notification.Name("com.pulkit.edith.notificationsChanged")
}

public struct AgentNotificationDelivery: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let identifier: String
    public let notification: AgentNotification?
    public let fireAt: Date?
    public let expiresAt: Date?

    public init(
        id: UUID = UUID(), identifier: String, notification: AgentNotification?,
        fireAt: Date? = nil, expiresAt: Date? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.notification = notification
        self.fireAt = fireAt
        self.expiresAt = expiresAt
    }
}

public enum AgentNotificationClient {
    public static func pending(client: AgentClient = .shared) throws -> [AgentNotificationDelivery]
    {
        let data = try client.performInternal(AgentNotificationOperation.pending, payload: Data())
        return try AgentPayload.decode([AgentNotificationDelivery].self, from: data)
    }

    public static func acknowledge(_ ids: [UUID], client: AgentClient = .shared) throws {
        _ = try client.performInternal(
            AgentNotificationOperation.acknowledge, payload: AgentPayload.encode(ids))
    }
}
