import EdithExtensionSupport
import Foundation
import Testing
@testable import LaTeXExtension

@Suite(.serialized) @MainActor struct LaTeXWorkerTests {
    @Test func commandAdmissionRejectsUnknownOversizedAndMalformedRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LaTeXModel(store: .init(url: root.appendingPathComponent("projects.json")))
        let worker = LaTeXWorker(model: model)
        for (command, payload) in [
            ("unknown", Data()), ("latex.projects", Data(repeating: 0, count: 524_289)),
            ("latex.addProject", Data("invalid".utf8)),
        ] {
            await #expect(throws: (any Error).self) {
                try await worker.execute(command, payload: payload)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await worker.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("latex.projects", payload: Data())
        }
    }

    @Test func draftCommandsRequireTheSelectedProjectAndItsSavedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mock.tex")
        try Data("synthetic source".utf8).write(to: source)
        let model = LaTeXModel(store: .init(url: root.appendingPathComponent("projects.json")))
        let worker = LaTeXWorker(model: model)
        let project = LaTeXProject(name: "Mock paper", location: .disk, sourcePath: source.path)
        _ = try await worker.execute("latex.addProject", payload: JSONEncoder().encode(project))
        let revision = try #require(model.original?.revision)
        for (id, version) in [(UUID(), revision), (project.id, "stale-revision")] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "projectID": id.uuidString, "revision": version, "text": "invalid draft",
            ])
            await #expect(throws: ExtensionPeerError.self) {
                try await worker.execute("latex.setDraft", payload: payload)
            }
        }
        #expect(model.source == "synthetic source" && !model.dirty)
        _ = try await worker.execute(
            "latex.setDraft",
            payload: JSONSerialization.data(withJSONObject: [
                "projectID": project.id.uuidString, "revision": revision, "text": "valid draft",
            ]))
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute(
                "latex.removeProject", payload: JSONEncoder().encode(project.id))
        }
        #expect(model.dirty && model.projects.count == 1)
        await worker.shutdown()
        #expect(try String(contentsOf: source, encoding: .utf8) == "synthetic source")
    }
}
