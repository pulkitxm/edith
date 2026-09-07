import EdithCore
import Foundation

public enum SystemMonitorClient {
    public static let descriptor = UserOperationDescriptor(
        id: UserOperationID(rawValue: "system.monitor.snapshot"),
        summary: "Read the background agent's system metrics.",
        cli: ["system", "stats"], effect: .read)

    public static func snapshot() async throws -> SystemMonitorSnapshot {
        try await AgentClient.shared.performAsync(
            SystemMonitorSnapshot.self, operation: descriptor.id)
    }
}
