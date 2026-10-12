import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalRuntimeTests {
    private func invoke(_ runtime: ExtensionRuntime, _ command: String, payload: Data = Data())
        async throws -> Data
    {
        try await withCheckedThrowingContinuation { continuation in
            runtime.invoke(["token": UUID().uuidString, "command": command, "payload": payload]) {
                data, message in
                if let data {
                    continuation.resume(returning: data as Data)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "TerminalFixture", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: message as String? ?? "Rejected"])
                    )
                }
            }
        }
    }

    @Test func runtimeUsesOwnedEngineAndUIStopDoesNotStopPTYs() async throws {
        let engine = TerminalTestFixture.engine()
        let runtime = ExtensionRuntime(makeEngine: { engine })
        defer { _ = runtime.execute(["operation": "stop"]) }
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        let started = try #require(
            runtime.execute(["operation": "start", "defaultsSuite": suite]) as? NSDictionary)
        #expect(started["ok"] as? Bool == true)
        let data = try await invoke(runtime, "terminal.open")
        let snapshot = try JSONDecoder().decode(TerminalEngine.Snapshot.self, from: data)
        #expect(snapshot.sessions.count == 1)
        let badUI = try #require(
            runtime.execute([
                "operation": "configureUI", "remoteUI": true, "engineClient": NSObject(),
            ]) as? NSDictionary)
        #expect(badUI["ok"] as? Bool == false)
        _ = runtime.execute(["operation": "stopUI"])
        #expect(try engine.snapshot().sessions.count == 1 && !engine.isStopped)
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        #expect(engine.isStopped)
        await #expect(throws: (any Error).self) { try await invoke(runtime, "terminal.snapshot") }
    }

    @Test func prepareToStopCancelsPendingRegistryReadBeforeReleasingEngine() async throws {
        let engine = TerminalTestFixture.engine()
        let runtime = ExtensionRuntime(makeEngine: { engine })
        defer { _ = runtime.execute(["operation": "stop"]) }
        let suite = try #require(ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"])
        _ = runtime.execute(["operation": "start", "defaultsSuite": suite])
        let snapshot = try JSONDecoder().decode(
            TerminalEngine.Snapshot.self, from: await invoke(runtime, "terminal.open"))
        let session = try #require(snapshot.sessions.first)
        let payload = try JSONEncoder().encode(
            TerminalEngine.ReadRequest(
                session: .init(id: session.id, generation: session.generation), offset: 0))
        let read = Task { try await invoke(runtime, "terminal.read", payload: payload) }
        try await Task.sleep(for: .milliseconds(10))
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
        await #expect(throws: (any Error).self) { try await read.value }
        #expect(engine.isStopped)
    }
}
