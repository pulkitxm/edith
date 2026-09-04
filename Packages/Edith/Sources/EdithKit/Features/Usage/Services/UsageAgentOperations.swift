import Foundation

public enum UsageAgentOperations {
    public static func requestRefresh(client: AgentClient = .shared) throws {
        _ = try client.perform(UsageCollectionOperation.refresh.descriptor.id)
    }

    public static func requestLimitsRefresh(client: AgentClient = .shared) throws {
        _ = try client.perform(UsageCollectionOperation.limitsRefresh.descriptor.id)
    }
}
