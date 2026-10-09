import Foundation

public enum UsageMachineRefreshPolicy: Int, Codable, Sendable {
    case skip
    case due
    case all
}

public enum UsageAgentOperations {
    @discardableResult
    public static func requestRefresh(
        machinePolicy: UsageMachineRefreshPolicy = .due, client: AgentClient = .shared
    ) throws -> String? {
        let response = try client.perform(
            UsageCollectionOperation.refresh.descriptor.id,
            payload: AgentPayload.encode(machinePolicy))
        return try? AgentPayload.decode(String.self, from: response)
    }

    public static func requestLimitsRefresh(client: AgentClient = .shared) throws {
        _ = try client.perform(UsageCollectionOperation.limitsRefresh.descriptor.id)
    }
}
