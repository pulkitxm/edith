import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXDraftTests {
    @Test func updatesRestoreUnsavedSourceWithoutChangingItsSavedRevision() async throws {
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
        #expect(restored.selectedID == id && restored.source == "synthetic unsaved draft")
        #expect(restored.original?.revision == revision && restored.dirty)
        #expect(restored.editorRequest > 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "synthetic saved source")
        restored.discard()
        await restored.shutdown()
        #expect(try store.loadDraft() == nil)
        let next = LaTeXModel(store: store)
        await next.start()
        #expect(next.projects.count == 1 && next.selectedID == nil && !next.dirty)
        await next.shutdown()
    }

    @Test func externallyChangedSourceKeepsTheDraftAndRejectsAnOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mock.tex")
        try Data("original".utf8).write(to: file)
        let store = LaTeXProjectStore(url: root.appendingPathComponent("projects.json"))
        let model = LaTeXModel(store: store)
        try await model.add(.init(name: "Mock paper", location: .disk, sourcePath: file.path))
        model.source = "draft"
        await model.shutdown()
        try Data("external change".utf8).write(to: file)
        let restored = LaTeXModel(store: store)
        await restored.start()
        #expect(throws: LaTeXError.self) {
            try LaTeXService.live.saveLocal(
                try #require(restored.selected), text: restored.source,
                original: try #require(restored.original))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "external change")
        await restored.shutdown()
    }
}
