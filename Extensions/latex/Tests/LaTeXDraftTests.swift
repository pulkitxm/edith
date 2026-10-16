import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXDraftTests {
    @Test func unsavedSourceIsNotPersistedAcrossLaunches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mock.tex")
        try Data("synthetic saved source".utf8).write(to: file)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let first = LaTeXModel(store: store)
        try await first.add(.init(name: "Mock paper", location: .disk, sourcePath: file.path))
        let id = try #require(first.selectedID)
        let revision = try #require(first.original?.revision)
        first.source = "synthetic unsaved draft"
        await first.shutdown()
        let restored = LaTeXModel(store: store)
        await restored.start()
        #expect(restored.selectedID == nil && restored.source.isEmpty && !restored.dirty)
        #expect(restored.editorRequest == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "synthetic saved source")
        await restored.shutdown()
        _ = id; _ = revision
    }
}
