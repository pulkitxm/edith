import EdithKit
import Foundation

public enum AgentScheduleOperations {
    public static func register(on runtime: AgentRuntime, service: ScheduleService) async {
        await runtime.registerShutdown(id: "schedules") { await service.shutdown() }
        await runtime.register(operation: AgentScheduleOperation.add) { payload in
            let definition = try AgentPayload.decode(ScheduledTaskDefinition.self, from: payload)
            return try await AgentPayload.encode(service.add(definition))
        }
        await runtime.register(operation: AgentScheduleOperation.list) { _ in
            try await AgentPayload.encode(service.list())
        }
        await runtime.register(operation: AgentScheduleOperation.remove) { payload in
            let request = try AgentPayload.decode(AgentScheduleNameRequest.self, from: payload)
            try await service.remove(request.name)
            return Data()
        }
        await runtime.register(operation: AgentScheduleOperation.setEnabled) { payload in
            let request = try AgentPayload.decode(AgentScheduleEnabledRequest.self, from: payload)
            return try await AgentPayload.encode(
                service.setEnabled(request.name, request.enabled))
        }
        await runtime.register(operation: AgentScheduleOperation.runNow) { payload in
            let request = try AgentPayload.decode(AgentScheduleNameRequest.self, from: payload)
            return try await AgentPayload.encode(service.runNow(request.name))
        }
    }
}
