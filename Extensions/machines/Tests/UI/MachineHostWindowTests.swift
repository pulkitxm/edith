import AppKit
import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineHostWindowTests {
    @Test func originalDetachButtonsRequestOwnedHostWindowsWithoutCreatingWorkerWindows()
        async throws
    {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let owner = MachineSession(machine: .local, local: true, synthetic: true)
        var opened: [MachineHostWindowRequest] = []
        let engine = MachineUIEngine(
            session: { id in
                guard id == owner.id else { throw MachineUIError.invalidRequest }; return owner
            },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            }, mutation: { _ in }, workspace: { _ in }, openWindow: { opened.append($0) })
        let bridge = MachineHostWindowBridge(engine: engine)
        let transport = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let client = MachineUIClient(client: transport)
        let previous = MachinesModel.shared
        let model = MachinesModel(uiClient: client)
        MachinesModel.shared = model
        defer { MachinesModel.shared = previous }
        let session = model.session(for: Machine.localID)
        let count = NSApp.windows.count
        MachineWindow.open(machineID: session.id, title: "Synthetic local machine")
        FinderWindow.open(session: session, path: "/synthetic/selected-folder")
        DockerWindow.open(session: session)
        TerminalWindow.open(session: session)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while opened.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Set(opened.map(\.kind.rawValue)) == ["machine", "files", "docker", "terminal"])
        #expect(
            opened.allSatisfy {
                $0.machineID == session.id && $0.presentationID == transport.presentationID
            })
        #expect(opened.first(where: { $0.kind == .files })?.path == "/synthetic/selected-folder")
        #expect(NSApp.windows.count == count)
        #expect(NSApp.windows.allSatisfy { !$0.isVisible })
        client.shutdown(); await engine.shutdown(); await owner.shutdown()
    }

    @Test func unavailableHostBridgeAndMalformedRequestsFailTruthfully() async throws {
        let session = MachineSession(machine: .local, local: true, synthetic: true)
        let engine = MachineUIEngine(
            session: { _ in session },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            }, mutation: { _ in }, workspace: { _ in })
        var value = MachineHostWindowRequest(
            kind: .files, machineID: session.id, path: "/synthetic", presentationID: UUID())
        let unavailable = try JSONDecoder().decode(
            MachineUIReply.self,
            from: await engine.execute(
                "machines.ui.openWindow", payload: JSONEncoder().encode(value)))
        #expect(unavailable.error == "The owning app window bridge is unavailable.")
        value.kind = .terminal
        let rejected = try JSONDecoder().decode(
            MachineUIReply.self,
            from: await engine.execute(
                "machines.ui.openWindow", payload: JSONEncoder().encode(value)))
        #expect(rejected.error != nil)
        await engine.shutdown(); await session.shutdown()
    }

    @Test func detachedWindowJobsRejectMismatchedPresentationBeforeHostInvocation() async throws {
        let owner = MachineSession(machine: .local, local: true, synthetic: true)
        var opened = false
        let engine = MachineUIEngine(
            session: { _ in owner },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            }, mutation: { _ in }, workspace: { _ in }, openWindow: { _ in opened = true })
        let origin = UUID()
        let request = MachineHostWindowRequest(
            kind: .terminal, machineID: owner.id,
            presentationID: UUID())
        for presentation in [origin, nil] as [UUID?] {
            let reply = try JSONDecoder().decode(
                MachineUIReply.self,
                from: await engine.execute(
                    "machines.ui.begin",
                    payload: JSONEncoder().encode(
                        MachineUIJobInput(
                            presentationID: presentation, operation: "machines.ui.openWindow",
                            payload: JSONEncoder().encode(request)))))
            #expect(reply.error != nil)
            #expect(!opened)
        }
        await engine.shutdown(); await owner.shutdown()
    }

    @Test func originalDefaultAppOpenMaterializesOnlyInTheEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.txt")
        try Data("synthetic document".utf8).write(to: file)
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        var presented: [URL] = []
        let previous = MachinesCLIEnvironment.presentURLs
        MachinesCLIEnvironment.presentURLs = { urls, action in
            #expect(action == .open); presented += urls; return true
        }
        defer { MachinesCLIEnvironment.presentURLs = previous }
        let engine = MachineUIEngine(
            session: { _ in session },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            }, mutation: { _ in }, workspace: { _ in })
        var value = MachineUIAction(operation: .openFile, machineID: session.id)
        value.entry = RemoteFileEntry(
            name: "fixture.txt", path: file.path, kind: .file, sizeBytes: 18)
        let response = try JSONDecoder().decode(
            MachineUIReply.self,
            from: await engine.execute("machines.ui.action", payload: JSONEncoder().encode(value)))
        #expect(response.error == nil)
        #expect(presented == [file])
        #expect(try Data(contentsOf: presented[0]) == Data("synthetic document".utf8))
        await engine.shutdown(); await session.shutdown()
    }
}

@MainActor private final class MachineHostWindowBridge: NSObject {
    let engine: MachineUIEngine
    init(engine: MachineUIEngine) { self.engine = engine }
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let request = try ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data as Data)
                let payload = try await engine.execute(request.operation, payload: request.payload)
                completion(
                    try ExtensionEngineWire.encode(
                        ExtensionEngineReply(token: request.token, ok: true, payload: payload))
                        as NSData)
            } catch { Issue.record(error) }
        }
    }
    @objc func cancel(_ token: NSString) {}
    @objc func invalidate() {}
}
