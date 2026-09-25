import EdithKit
import Foundation

public enum AgentJev {
    public static let engine = JevEngine(
        store: KeychainJevKeyStore(),
        onKeyChange: { JevAvailability.record(configured: $0) })
}

public enum AgentJevOperations {
    public static func register(on runtime: AgentRuntime, engine: JevEngine = AgentJev.engine)
        async
    {
        await runtime.register(operation: JevAgentOperation.decide) { payload in
            let call = try AgentPayload.decode(JevCall.self, from: payload)
            do {
                let decision = try await engine.decide(call.request, purpose: call.purpose)
                return try AgentPayload.encode(JevReply(decision: decision))
            } catch let error as JevError {
                return try AgentPayload.encode(JevReply(error: error))
            }
        }
        await runtime.register(operation: JevAgentOperation.status) { payload in
            let query =
                payload.isEmpty
                ? JevStatusQuery(probe: false)
                : try AgentPayload.decode(JevStatusQuery.self, from: payload)
            return try await AgentPayload.encode(engine.status(probe: query.probe))
        }
        await runtime.register(operation: JevAgentOperation.setKey) { payload in
            let update = try AgentPayload.decode(JevKeyUpdate.self, from: payload)
            await engine.setKey(update.key)
            return try await AgentPayload.encode(engine.status(probe: update.key != nil))
        }
        _ = await engine.isConfigured
    }
}
