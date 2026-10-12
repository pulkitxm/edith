import EdithExtensionSupport
import Foundation
import Testing

@testable import MachinesExtension

@Suite(.serialized) @MainActor struct MachineDirectoryExportTests {
    @Test func actualDirectoryFacadePreservesBinaryHiddenEmptyFoldersAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("fixture-folder")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<150000).map { UInt8($0 % 251) })
        try bytes.write(to: source.appendingPathComponent(".binary"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path, withDestinationPath: ".binary")
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let exports = MachineDirectoryExport(session: { id in
            guard id == session.id else { throw MachineUIError.invalidRequest }; return session
        })
        let engine = MachineUIEngine(
            session: { _ in session },
            state: {
                MachineUIState(
                    machines: [], forwards: [], snippets: [], sessions: [], workspaces: .init())
            }, mutation: { _ in }, workspace: { _ in },
            directoryExport: { try await exports.execute($0) })
        let bridge = MachineExportBridge(engine: engine)
        let transport = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let client = MachineUIClient(client: transport)
        let entry = RemoteFileEntry(
            name: source.lastPathComponent, path: source.path, kind: .directory, sizeBytes: 0)
        let result = try await client.materializeDirectory(entry: entry, machineID: session.id)
        defer { try? FileManager.default.removeItem(at: result.deletingLastPathComponent()) }
        #expect(result.path != source.path)
        #expect(try Data(contentsOf: result.appendingPathComponent(".binary")) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: result.appendingPathComponent("empty").path
            ).isEmpty)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: result.appendingPathComponent("link").path) == ".binary")
        #expect(bridge.operations.first == "machines.ui.begin")
        #expect(bridge.operations.contains("machines.ui.export"))
        exports.shutdown(); await engine.shutdown(); client.shutdown(); await session.shutdown()
    }

    @Test func exportRejectsChangedOwnershipStaleCursorTraversalAndOversizedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 7, count: 70000).write(to: root.appendingPathComponent("bytes"))
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let engine = MachineDirectoryExport(session: { _ in session })
        let entry = RemoteFileEntry(
            name: root.lastPathComponent, path: root.path, kind: .directory, sizeBytes: 0)
        let prepared = try await engine.execute(
            .init(operation: .prepare, machineID: session.id, entry: entry))
        let handle = try JSONDecoder().decode(MachineDirectoryExportHandle.self, from: prepared)
        var read = MachineDirectoryExportRequest(
            operation: .read, machineID: session.id, id: handle.id,
            path: root.lastPathComponent + "/bytes")
        let chunk = try JSONDecoder().decode(
            MachinePreviewChunk.self, from: await engine.execute(read))
        #expect(chunk.bytes.count == 65536)
        await #expect(throws: MachineUIError.stale) { try await engine.execute(read) }
        read.machineID = UUID(); read.offset = 65536
        await #expect(throws: MachineUIError.self) { try await engine.execute(read) }
        #expect(!MachineDirectoryExportRequest.validPath("fixture/../other"))
        await #expect(throws: RemoteFileOperationError.self) {
            try await engine.execute(
                .init(operation: .prepare, machineID: session.id, entry: entry, maximumBytes: 128))
        }
        engine.shutdown()
        await #expect(throws: MachineUIError.self) { try await engine.execute(read) }
        await session.shutdown()
    }
}

@MainActor private final class MachineExportBridge: NSObject {
    let engine: MachineUIEngine
    var operations: [String] = []
    init(engine: MachineUIEngine) { self.engine = engine }
    @objc func invoke(_ data: NSData, completion: @escaping @Sendable (NSData) -> Void) {
        Task {
            do {
                let request = try ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data as Data)
                operations.append(request.operation)
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
