import EdithExtensionSupport
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor
@Suite struct StudioCommandTests {
    private func fixture() throws -> (URL, StudioModel, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "test.studio.commands.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (directory, StudioModel(defaults: defaults, loadsState: false), suite)
    }

    private func cleanup(_ directory: URL, model: StudioModel, suite: String) {
        model.shutdown()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func execute(
        _ command: String, object: [String: Any], model: StudioModel,
        workflows: URL? = nil
    ) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try await StudioCommands.execute(
            command, payload: data, model: model, workflowDirectory: workflows ?? DataRoot.studio)
    }

    @Test func admissionRejectsUnknownNullOversizedAndMalformedRequests() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let original = directory.appendingPathComponent("original.openscreen")
        let source = Data("synthetic source".utf8)
        try source.write(to: original)
        for payload in [
            Data(), Data("[]".utf8), Data("null".utf8), Data("{\"\":true}".utf8),
            Data("{\"unknown\":true}".utf8), Data("{\"recent\":null}".utf8),
            Data(repeating: 32, count: StudioCommands.maximumRequestBytes + 1),
        ] {
            await #expect(throws: (any Error).self) {
                try await StudioCommands.execute(
                    "studio.library.clear", payload: payload, model: model)
            }
        }
        await #expect(throws: StudioCommands.Failure.self) {
            try await StudioCommands.execute(
                "studio.unregistered", payload: Data("{}".utf8), model: model)
        }
        #expect(try Data(contentsOf: original) == source)
    }

    @Test func deeplyNestedAndMalformedJSONIsRejectedBeforeRecursiveDecoding() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        for depth in [17, 1_000, 30_000] {
            let raw =
                "{\"options\":" + String(repeating: "[", count: depth)
                + "0" + String(repeating: "]", count: depth) + "}"
            do {
                _ = try await StudioCommands.execute(
                    "studio.tools.run", payload: Data(raw.utf8), model: model)
                Issue.record("An over-deep JSON command was admitted.")
            } catch let error as StudioCommands.Failure {
                #expect(error == .invalid("JSON nesting exceeds 16 levels."))
            }
        }
        for raw in ["{", "{\"query\":\"unterminated}", "{\"query\": [1,2,]}"] {
            await #expect(throws: StudioCommands.Failure.self) {
                try await StudioCommands.execute(
                    "studio.tools.list", payload: Data(raw.utf8), model: model)
            }
        }
        let brackets = String(repeating: "[]{}", count: 100)
        let accepted = try await execute(
            "studio.tools.list", object: ["query": brackets], model: model)
        #expect((try JSONSerialization.jsonObject(with: accepted) as? [Any])?.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func localPathsRejectRemoteRelativeAndControlCharacterInputs() throws {
        for path in [
            "relative.mov", "~/source.mov", "file:///tmp/source.mov",
            "https://example.com/source.mov",
            "//server/share.mov", "/tmp/file\nname.mov", "/tmp/file\0name.mov",
            "/" + String(repeating: "x", count: 4_096),
        ] {
            #expect(throws: StudioCommands.Failure.self) { try StudioCommands.localPath(path) }
        }
        #expect(try StudioCommands.localPath("/tmp/a/../source.mov").path == "/tmp/source.mov")
    }

    @Test func libraryMutationsPersistAndNeverChangeSources() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let source = directory.appendingPathComponent("synthetic.mov")
        let bytes = Data("synthetic source media".utf8)
        try bytes.write(to: source)
        let added = try await execute(
            "studio.library.add", object: ["paths": [source.path]], model: model)
        #expect(
            try JSONDecoder().decode([StudioMediaItem].self, from: added).map(\.url) == [source])
        let other = try #require(UserDefaults(suiteName: suite))
        #expect(try StudioMediaLibrary.list(defaults: other).map(\.url) == [source])
        let listed = try await execute("studio.library.list", object: [:], model: model)
        #expect(
            try JSONDecoder().decode([StudioMediaItem].self, from: listed).map(\.url) == [source])
        _ = try await execute(
            "studio.library.remove", object: ["paths": [source.path]], model: model)
        #expect(try StudioMediaLibrary.list(defaults: other).isEmpty)
        _ = try await execute("studio.library.add", object: ["paths": [source.path]], model: model)
        _ = try await execute("studio.library.clear", object: [:], model: model)
        #expect(try StudioMediaLibrary.list(defaults: other).isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
        await #expect(throws: (any Error).self) {
            try await execute(
                "studio.library.add", object: ["paths": Array(repeating: source.path, count: 501)],
                model: model)
        }
        #expect(try StudioMediaLibrary.list(defaults: other).isEmpty)
    }

    @Test func toolCatalogAndSchemaExposeActualNativeOptions() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let result = try await execute("studio.tools.list", object: [:], model: model)
        let tools = try #require(JSONSerialization.jsonObject(with: result) as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["id"] as? String }) == Set(StudioCatalog.tools.map(\.id)))
        let schema = try await execute(
            "studio.tools.schema", object: ["toolID": "image.resize"], model: model)
        let object = try #require(JSONSerialization.jsonObject(with: schema) as? [String: Any])
        let options = try #require(object["options"] as? [[String: Any]])
        let original = try #require(StudioCatalog.tool("image.resize"))
        #expect(options.compactMap { $0["key"] as? String } == original.options.map(\.key))
        #expect(object["runnable"] as? Bool == original.isRunnable)
    }

    @Test func nativeImageToolRunsAndProtectsTheOriginal() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let source = directory.appendingPathComponent("synthetic.png")
        try StudioTestFiles.image(source, width: 64, height: 32)
        let before = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let data = try await execute(
            "studio.tools.run",
            object: ["toolID": "image.resize", "paths": [source.path], "output": output.path],
            model: model)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outputs = try #require(result["outputs"] as? [[String: Any]])
        #expect(outputs.count == 1)
        let file = try #require(outputs.first?["url"] as? String)
        let url = try #require(URL(string: file))
        #expect(url.deletingLastPathComponent().standardizedFileURL == output.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: source) == before)
        await #expect(throws: (any Error).self) {
            try await execute(
                "studio.tools.run",
                object: [
                    "toolID": "image.resize", "paths": [source.path], "output": output.path,
                    "options": ["unrecognized": "true"],
                ], model: model)
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func workflowsSaveRunAndRemoveRealToolChains() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let workflows = directory.appendingPathComponent("workflows", isDirectory: true)
        let source = directory.appendingPathComponent("synthetic.png")
        try StudioTestFiles.image(source, width: 64, height: 32)
        let bytes = try Data(contentsOf: source)
        let saved = try await execute(
            "studio.workflows.save",
            object: ["name": "Synthetic image resize", "steps": [["toolID": "image.resize"]]],
            model: model, workflows: workflows)
        let workflow = try JSONDecoder().decode(StudioWorkflow.self, from: saved)
        #expect(StudioWorkflowFile.load(from: workflows).contains { $0.id == workflow.id })
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let run = try await execute(
            "studio.workflows.run",
            object: ["id": workflow.id.uuidString, "paths": [source.path], "output": output.path],
            model: model, workflows: workflows)
        let result = try #require(JSONSerialization.jsonObject(with: run) as? [String: Any])
        #expect((result["outputs"] as? [Any])?.count == 1)
        #expect(try Data(contentsOf: source) == bytes)
        _ = try await execute(
            "studio.workflows.remove", object: ["id": workflow.id.uuidString], model: model,
            workflows: workflows)
        #expect(!StudioWorkflowFile.load(from: workflows).contains { $0.id == workflow.id })
        let before = try Data(contentsOf: StudioWorkflowFile.url(in: workflows))
        await #expect(throws: (any Error).self) {
            try await execute(
                "studio.workflows.save",
                object: [
                    "name": "Rejected", "steps": [["toolID": "image.resize", "unknown": true]],
                ], model: model, workflows: workflows)
        }
        #expect(try Data(contentsOf: StudioWorkflowFile.url(in: workflows)) == before)
    }

    @Test func projectCommandsPreserveRevisionAndRejectUnknownPlanFields() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let project = directory.appendingPathComponent("synthetic.openscreen")
        let created = try await execute(
            "studio.edit.create", object: ["path": project.path, "title": "Synthetic project"],
            model: model)
        #expect(try JSONDecoder().decode(VideoEditorService.Result.self, from: created).written)
        let original = try Data(contentsOf: project)
        let revision = try VideoEditorService.readProject(project).revision.fingerprint.hexDigest
        let plan: [String: Any] = ["version": 1, "operations": [["rename": ["title": "Updated"]]]]
        let dry = try await execute(
            "studio.edit.apply",
            object: [
                "path": project.path, "plan": plan, "dryRun": true, "expectedRevision": revision,
            ], model: model)
        #expect(try !JSONDecoder().decode(VideoEditorService.Result.self, from: dry).written)
        #expect(try Data(contentsOf: project) == original)
        let committed = try await execute(
            "studio.edit.apply",
            object: [
                "path": project.path, "plan": plan, "overwrite": true, "expectedRevision": revision,
            ], model: model)
        let response = try JSONDecoder().decode(VideoEditorService.Result.self, from: committed)
        #expect(response.written && response.sourceRevision == revision)
        #expect(try VideoEditorService.open(project).title == "Updated")
        let final = try Data(contentsOf: project)
        await #expect(throws: (any Error).self) {
            try await execute(
                "studio.edit.apply",
                object: [
                    "path": project.path, "plan": plan, "overwrite": true,
                    "expectedRevision": revision,
                ], model: model)
        }
        await #expect(throws: (any Error).self) {
            try await execute(
                "studio.edit.apply",
                object: [
                    "path": project.path,
                    "plan": ["version": 1, "operations": [], "unexpected": true], "overwrite": true,
                ], model: model)
        }
        #expect(try Data(contentsOf: project) == final)
        let validated = try await execute(
            "studio.edit.validate", object: ["path": project.path], model: model)
        #expect(try !JSONDecoder().decode(VideoEditorService.Result.self, from: validated).written)
    }

    @Test func cancelledCommandsCannotCreateProjects() async throws {
        let (directory, model, suite) = try fixture()
        defer { cleanup(directory, model: model, suite: suite) }
        let project = directory.appendingPathComponent("cancelled.openscreen")
        let task = Task { @MainActor in
            try await execute(
                "studio.edit.create", object: ["path": project.path, "title": "Cancelled"],
                model: model)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled command created a project.")
        } catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: project.path))
    }
}
