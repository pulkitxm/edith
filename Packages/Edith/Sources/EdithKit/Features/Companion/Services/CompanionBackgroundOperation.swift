import Foundation

public enum CompanionBackgroundOperation {
    public static let refresh = "companion.background.refresh"
    public static let outboxChanged = Notification.Name("com.pulkit.edith.companionOutboxChanged")

    public static func requestRefresh() async throws {
        _ = try await Task.detached(priority: .utility) {
            try AgentClient.shared.performInternal(refresh)
        }.value
    }
}
