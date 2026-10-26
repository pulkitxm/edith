import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineEngineModelsTests {
    @Test func presentationsRetainSavedRecordsAndNeverReplaceEngineSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousRoot = MachinePaths.root
        let previousMachines = MachinesModel.shared
        let previousWorkspace = WorkspaceModel.shared
        MachinePaths.root = root
        defer {
            MachinePaths.root = previousRoot
            MachinesModel.shared = previousMachines
            WorkspaceModel.shared = previousWorkspace
            try? FileManager.default.removeItem(at: root)
        }
        MachinePaths.prepare()
        let saved = [
            Machine(name: "Synthetic first", host: "first.invalid"),
            Machine(name: "Synthetic second", host: "second.invalid"),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: MachinePaths.machinesFile)
        let engine = MachineEngineModels()
        let session = engine.machines.session(for: saved[0].id)
        for _ in 0..<2 {
            let bridge = MachineModelsBridge()
            let transport = try #require(
                ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
            let client = MachineUIClient(client: transport)
            let presentation = MachinesModel(uiClient: client)
            let workspace = WorkspaceModel(machines: presentation)
            MachinesModel.shared = presentation
            WorkspaceModel.shared = workspace
            #expect(presentation.store.machines.isEmpty)
            presentation.applyUIState(engine.state())
            #expect(presentation.store.machines.map(\.id) == saved.map(\.id))
            #expect(engine.machines.session(for: saved[0].id) === session)
            #expect(presentation.session(for: saved[0].id) !== session)
            await workspace.shutdown()
            await presentation.shutdown()
            client.shutdown()
            #expect(engine.state().machines.map(\.id) == saved.map(\.id))
            #expect(engine.machines.session(for: saved[0].id) === session)
        }
        await engine.shutdown()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(
            try decoder.decode(
                [Machine].self, from: Data(contentsOf: MachinePaths.machinesFile)
            ).map(\.id) == saved.map(\.id))
    }
}

@MainActor private final class MachineModelsBridge: NSObject {
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {}
    @objc func cancel(_ token: NSString) {}
}
