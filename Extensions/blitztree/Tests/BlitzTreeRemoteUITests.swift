import EdithExtensionSupport
import Foundation
import Testing
@testable import BlitzTreeExtension

@Suite(.serialized) @MainActor struct BlitzTreeRemoteUITests {
    @Test func originalRemoteScanShowsNativeFilesystemAndDisableRejectsLateWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "synthetic.blitz.remote." + UUID().uuidString
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 8192).write(to: root.appendingPathComponent("fixture.bin"))
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BlitzTreeModel()
        let bridge = Bridge(owner: owner)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let remote = BlitzTreeModel(engineClient: client)
        remote.scan(root.path)
        for _ in 0..<2000 {
            await remote.refreshRemote()
            if remote.report != nil && !remote.scanning { break }
            await Task.yield()
        }
        #expect(remote.report?.root == (try BlitzTreeScanner.resolvedDirectory(root.path)))
        #expect(remote.report?.summary.fileCount == 1)
        #expect(remote.report?.report.inventory.largestChildren.first?.logicalBytes == 8192)
        let stale = BlitzTreeUITrash(
            path: root.appendingPathComponent("fixture.bin").path, confirmed: true,
            previewToken: UUID())
        await #expect(throws: ExtensionPeerError.self) {
            try await BlitzTreeCommands.execute(
                "blitztree.ui.trash", payload: JSONEncoder().encode(stale), model: owner)
        }
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture.bin").path))
        await remote.shutdown(); client.invalidate(); await owner.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await BlitzTreeCommands.execute(
                "blitztree.ui.snapshot", payload: Data("{}".utf8), model: owner)
        }
    }
    @MainActor private final class Bridge: NSObject {
        let owner: BlitzTreeModel
        let registry = ExtensionCommandRegistry()
        init(owner: BlitzTreeModel) { self.owner = owner }
        @objc func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
            guard
                let request = try? ExtensionEngineWire.decode(
                    ExtensionEngineRequest.self, from: data)
            else { completion(Data()); return }
            registry.invoke(
                [
                    "token": request.token.uuidString, "command": request.operation,
                    "payload": request.payload,
                ],
                completion: { bytes, error in
                    completion(
                        (try? ExtensionEngineWire.encode(
                            ExtensionEngineReply(
                                token: request.token, ok: error == nil && bytes != nil,
                                payload: bytes as Data? ?? Data("{}".utf8)))) ?? Data())
                },
                execute: { [owner] in
                    try await BlitzTreeCommands.execute($0, payload: $1, model: owner)
                })
        }
        @objc func cancel(_ token: String) { registry.cancel(token) }
    }
}
