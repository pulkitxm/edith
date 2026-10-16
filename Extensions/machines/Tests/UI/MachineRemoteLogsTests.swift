import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineRemoteLogsTests {
    @Test func originalLogViewReceivesEngineLinesWithoutCreatingPublicProcesses() async throws {
        let owner = MachineSession(machine: .local, local: true, synthetic: true)
        let container = DockerContainer(
            id: "fixture", names: ["fixture"], image: "fixture", command: "", state: .running,
            status: "Up")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "printf '2026-01-01T00:00:00Z original log\\n'; printf 'failure\\n' >&2; exec sleep 30",
        ]
        let engine = MachineLogEngine(
            session: { _ in owner }, containers: { _ in [container] }, process: { _, _ in process })
        let bridge = MachineRemoteLogBridge(engine: engine)
        let transport = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let client = MachineUIClient(client: transport)
        let session = MachineSession(machine: .local, local: true, uiClient: client)
        var state = owner.uiState()
        state.containers = [container]
        session.applyUIState(state)
        let model = DockerDetailModel { _, _ in
            Issue.record("The public view created a log process")
            return nil
        }
        model.startLogs(session: session, container: container)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.logs.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.logs.first(where: { !$0.isStderr })?.text == "original log")
        #expect(model.logs.first(where: { !$0.isStderr })?.timestamp == "2026-01-01T00:00:00Z")
        #expect(model.logs.filter(\.isStderr).count == 1)
        #expect(model.logs.first(where: { $0.isStderr })?.text == "failure")
        #expect(session.connectionRef == nil)
        model.stop()
        while !bridge.operations.contains(.cancel), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.operations.contains(.cancel))
        await engine.shutdown()
        client.shutdown()
        #expect(!process.isRunning)
    }
}

@MainActor private final class MachineRemoteLogBridge: NSObject {
    let engine: MachineLogEngine
    var operations: [MachineLogRequest.Operation] = []

    init(engine: MachineLogEngine) { self.engine = engine }

    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data)
            guard request.operation == "machines.ui.logs" else {
                throw MachineUIError.invalidRequest
            }
            let value = try JSONDecoder().decode(MachineLogRequest.self, from: request.payload)
            operations.append(value.operation)
            let frame = try engine.execute(value)
            let payload = try JSONEncoder().encode(
                MachineUIReply(value: JSONEncoder().encode(frame), error: nil))
            completion(
                try ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: request.token, ok: true, payload: payload))
                    as NSData)
        } catch { Issue.record(error) }
    }

    @objc func cancel(_ token: NSString) {}
    @objc func invalidate() {}
}
