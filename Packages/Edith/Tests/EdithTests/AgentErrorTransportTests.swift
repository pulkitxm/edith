import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentErrorTransportTests {
    @Test(arguments: [AgentError.Kind.unavailable, .refused, .cancelled])
    func remoteFailuresRetainTheirKindAndLeaveTheConnectionUsable(_ kind: AgentError.Kind)
        async throws
    {
        let runtime = AgentRuntime(build: "error-transport-fixture", store: nil)
        await runtime.register(operation: AgentDiagnostics.runJob) { _ in
            if kind == .cancelled { throw CancellationError() }
            throw AgentError(kind, "Fixture \(kind.rawValue) response.")
        }
        await runtime.register(operation: AgentDiagnostics.cancelJob) { _ in
            try AgentPayload.encode(true)
        }
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        let message =
            kind == .cancelled
            ? "The background operation was cancelled." : "Fixture \(kind.rawValue) response."
        await #expect(throws: AgentError(kind, message)) {
            try await client.performInternalAsync(AgentDiagnostics.runJob)
        }
        #expect(
            try AgentPayload.decode(
                Bool.self, from: await client.performInternalAsync(AgentDiagnostics.cancelJob))
        )
        await runtime.shutdown()
    }

    @Test func errorEnvelopesBoundDiagnosticsAndRejectMalformedResponses() {
        let response = AgentError.response(
            AgentError(.refused, String(repeating: "x", count: 100_000)))
        let decoded = AgentError.fromResponse(response)
        #expect(decoded.kind == .refused)
        #expect(decoded.message.count == 16_384)
        #expect(
            AgentError.fromResponse("Fixture malformed response.")
                == AgentError(.failed, "Fixture malformed response."))
        #expect(
            AgentError.fromResponse(String(repeating: "x", count: 200_000)).message.count == 16_384)
    }
}
