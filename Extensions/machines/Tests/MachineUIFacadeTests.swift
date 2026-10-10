import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineUIFacadeTests {
    @Test func checkedActionsRejectMalformedParameters() throws {
        var action = MachineUIAction(operation: .observe, machineID: UUID())
        #expect(throws: MachineUIError.invalidRequest) { try action.validate() }
        action.token = UUID()
        try action.validate()
        action.timeout = .infinity
        #expect(throws: MachineUIError.invalidRequest) { try action.validate() }
        action.timeout = 30
        action.text = "invalid\0path"
        #expect(throws: MachineUIError.invalidRequest) { try action.validate() }
    }

    @Test func fixedEngineFileActionUsesOwnedSessionAndRealIsolatedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachineUIEngine(
            session: { id in
                guard id == session.id else { throw MachineUIError.invalidRequest }; return session
            },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            },
            mutation: { _ in throw MachineUIError.invalidRequest }, workspace: { _ in })
        var action = MachineUIAction(operation: .mkdir, machineID: session.id)
        action.text = root.appendingPathComponent("created-by-engine").path
        let reply = try await engine.execute(
            "machines.ui.action", payload: JSONEncoder().encode(action))
        let envelope = try JSONDecoder().decode(MachineUIReply.self, from: reply)
        #expect(envelope.error == nil)
        #expect(FileManager.default.fileExists(atPath: action.text))
        action.operation = .listFiles
        action.text = root.path
        let listing = try await engine.execute(
            "machines.ui.action", payload: JSONEncoder().encode(action))
        let data = try #require(JSONDecoder().decode(MachineUIReply.self, from: listing).value)
        #expect(
            try JSONDecoder().decode([RemoteFileEntry].self, from: data).map(\.name) == [
                "created-by-engine"
            ])
        engine.stop()
        let disabled = try await engine.execute(
            "machines.ui.action", payload: JSONEncoder().encode(action))
        #expect(try JSONDecoder().decode(MachineUIReply.self, from: disabled).error != nil)
        await session.shutdown()
    }

    @Test func publicSessionCreatesNoConnectionOrLocalSamplerAndUsesFixedEngineAction() async throws
    {
        let bridge = MachineUIBridge()
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let facade = MachineUIClient(client: client)
        let session = MachineSession(machine: .local, local: true, uiClient: facade)
        #expect(session.connectionRef == nil)
        #expect(!session.collectsMetricsLocally)
        let result = await session.createDirectory(path: "/synthetic/owned-directory")
        #expect(try result.get().path == "/synthetic/owned-directory")
        #expect(bridge.requests.map(\.operation) == ["machines.ui.begin", "machines.ui.poll"])
        let job = try JSONDecoder().decode(MachineUIJobInput.self, from: bridge.requests[0].payload)
        #expect(job.operation == "machines.ui.action")
        let action = try JSONDecoder().decode(MachineUIAction.self, from: job.payload)
        #expect(action.operation == .mkdir)
        #expect(action.machineID == Machine.localID)
        facade.shutdown()
    }

    @Test func cancelledClientRejectsLateRepliesWithoutApplyingState() async throws {
        let bridge = MachineUIBridge()
        bridge.hold = true
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let facade = MachineUIClient(client: client)
        var delivered = false
        facade.receive = { _ in delivered = true }
        let request = Task { try await facade.refresh() }
        while bridge.requests.isEmpty { await Task.yield() }
        facade.shutdown()
        bridge.completeHeld()
        do {
            try await request.value; Issue.record("A disabled UI accepted a pending response")
        } catch {}
        #expect(!delivered)
        #expect(!bridge.cancelled.isEmpty)
    }
}

@MainActor private final class MachineUIBridge: NSObject {
    var requests: [ExtensionEngineRequest] = []
    var cancelled: [String] = []
    var hold = false
    private var waiting: (@Sendable (NSData) -> Void)?
    private var response: NSData?

    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        do {
            let request = try ExtensionEngineWire.decode(
                ExtensionEngineRequest.self, from: data as Data)
            requests.append(request)
            let value = try JSONEncoder().encode(
                RemoteDirectoryCreation(
                    machineName: "Local fixture", path: "/synthetic/owned-directory"))
            let payloadValue: Data
            if request.operation == "machines.ui.begin" {
                payloadValue = try JSONEncoder().encode(UUID())
            } else if request.operation == "machines.ui.poll" {
                payloadValue = try JSONEncoder().encode(
                    MachineUIJobState(
                        complete: true, reply: MachineUIReply(value: value, error: nil)))
            } else {
                payloadValue = value
            }
            let payload = try JSONEncoder().encode(MachineUIReply(value: payloadValue, error: nil))
            let reply =
                try ExtensionEngineWire.encode(
                    ExtensionEngineReply(token: request.token, ok: true, payload: payload))
                as NSData
            if hold { waiting = completion; response = reply } else { completion(reply) }
        } catch { Issue.record(error) }
    }

    @objc func cancel(_ token: NSString) { cancelled.append(token as String) }

    func completeHeld() {
        if let response { waiting?(response) }
        waiting = nil; response = nil
    }
}
