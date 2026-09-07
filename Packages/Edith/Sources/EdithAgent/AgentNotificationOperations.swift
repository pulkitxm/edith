import EdithKit
import Foundation

public enum AgentNotificationOperations {
    public static func register(
        on runtime: AgentRuntime, service: AgentNotificationService = .shared
    ) async {
        await runtime.register(operation: AgentNotificationOperation.pending) { _ in
            try await AgentPayload.encode(service.pending())
        }
        await runtime.register(operation: AgentNotificationOperation.acknowledge) { payload in
            try await service.acknowledge(AgentPayload.decode([UUID].self, from: payload))
            return Data()
        }
        do {
            try await service.start()
        } catch {
            AgentLog.logger.error(
                "notification state unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }
}
