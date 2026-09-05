import EdithKit
import Foundation

public enum AgentTaskOperations {
    public static func register(on runtime: AgentRuntime, service: AgentTaskService) async {
        await runtime.registerShutdown(id: "tasks") { await service.shutdown() }
        await runtime.register(operation: AgentTaskOperation.submit) { payload in
            let request = try AgentPayload.decode(AgentTaskSubmission.self, from: payload)
            return try await AgentPayload.encode(service.submit(request))
        }
        await runtime.register(operation: AgentTaskOperation.status) { payload in
            let request = try AgentPayload.decode(AgentTaskIDRequest.self, from: payload)
            return try await AgentPayload.encode(service.status(request.id))
        }
        await runtime.register(operation: AgentTaskOperation.cancel) { payload in
            let request = try AgentPayload.decode(AgentTaskIDRequest.self, from: payload)
            return try await AgentPayload.encode(service.cancel(request.id))
        }
        await runtime.register(operation: AgentTaskOperation.list) { _ in
            try await AgentPayload.encode(service.snapshots())
        }
        if let payload = try? await AgentPayload.encode(service.snapshots()) {
            await runtime.publish(topic: .tasks, payload: payload)
        }
    }
}
