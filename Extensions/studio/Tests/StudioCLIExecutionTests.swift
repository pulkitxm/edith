import EdithExtensionCommands
import EdithExtensionSupport
import EdithStudio
import Foundation
import Testing
@testable import StudioExtension

@MainActor @Suite(.serialized) struct StudioCLIExecutionTests {
    private func run(_ arguments: [String], model: StudioModel) async throws -> ExtensionCLIReply {
        try await StudioCLIExecution.run(
            ExtensionCLIRequest(arguments: arguments, workingDirectory: "/tmp"), model: model)
    }

    private func fixture() throws -> (URL, StudioModel, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "studio.cli.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (directory, StudioModel(defaults: defaults, loadsState: false), suite)
    }

    private func cleanup(_ directory: URL, _ model: StudioModel, _ suite: String) {
        model.shutdown()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func originalTreeHelpIncludesEveryCommandGroup() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        for path in [
            [], ["edit"], ["edit", "media"], ["edit", "audio"], ["edit", "captions"],
            ["edit", "markers"], ["edit", "publications"], ["workflow"], ["library"], ["record"],
        ] {
            let reply = try await run(path + ["--help"], model: model)
            #expect(reply.exitCode == 0)
            #expect(reply.stderr.isEmpty)
            #expect(reply.stdout.contains("USAGE:"))
        }
        let rootHelp = try await run(["--help"], model: model)
        for command in [
            "tools", "info", "run", "cancel", "reveal", "open", "probe", "edit", "record",
        ] {
            #expect(rootHelp.stdout.contains(command))
        }
        let editHelp = try await run(["edit", "--help"], model: model)
        for command in ["render", "render-audio", "review", "contact-sheet", "trash", "clone"] {
            #expect(editHelp.stdout.contains(command))
        }
    }

    @Test func libraryCLIUsesOwnedDefaultsAndPreservesSource() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        let source = root.appendingPathComponent("synthetic.txt")
        let original = Data("Synthetic Studio media fixture\n".utf8)
        try original.write(to: source)
        let added = try await run(["library", "add", source.path, "--json"], model: model)
        #expect(added.exitCode == 0 && added.stderr.isEmpty)
        #expect(added.stdout.contains(source.path))
        let listed = try await run(["library", "list"], model: model)
        #expect(listed.stdout == source.path + "\n")
        #expect(try StudioMediaLibrary.list(defaults: model.defaults).map(\.url) == [source])
        let removed = try await run(["library", "remove", source.path], model: model)
        #expect(removed.exitCode == 0)
        #expect(try StudioMediaLibrary.list(defaults: model.defaults).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func originalEditCreateApplyValidateShowAndFrameUseNativeEngine() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        let project = root.appendingPathComponent("synthetic.openscreen")
        let created = try await run(
            ["edit", "create", project.path, "--title", "Synthetic cut", "--json"], model: model)
        #expect(created.exitCode == 0 && created.stderr.isEmpty)
        #expect(try VideoProject.open(project).title == "Synthetic cut")
        let movie = try await VideoEditorServiceTests.movie(in: root)
        let plan = root.appendingPathComponent("plan.json")
        try JSONEncoder().encode(
            VideoEditPlan(operations: [.addMedia(path: movie.path, name: "intro")])
        ).write(to: plan)
        let applied = try await run(
            ["edit", "apply", project.path, "--plan", plan.path, "--overwrite", "--json"],
            model: model)
        #expect(applied.exitCode == 0 && applied.stderr.isEmpty)
        let saved = try VideoProject.open(project)
        #expect(saved.clips.count == 1)
        let shown = try await run(["edit", "show", project.path, "--json"], model: model)
        #expect(shown.exitCode == 0 && shown.stdout.contains("Synthetic cut"))
        let validated = try await run(["edit", "validate", project.path, "--json"], model: model)
        #expect(validated.exitCode == 0)
        let frame = root.appendingPathComponent("frame.png")
        let sampled = try await run(
            ["edit", "frame", project.path, "--frame", "0", "--output", frame.path, "--json"],
            model: model)
        #expect(sampled.exitCode == 0)
        #expect((StudioImageIO.info(frame)?.width ?? 0) > 0)
    }

    @Test func originalReviewContactSheetAndExportCommandsProduceMeasuredArtifacts() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        let source = try await VideoEditorServiceTests.movie(in: root)
        let project = root.appendingPathComponent("delivery.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic delivery")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [.addMedia(path: source.path, name: "intro")]),
            to: project, overwrite: true)
        let output = root.appendingPathComponent("delivery.mp4")
        let rendered = try await run(
            ["edit", "render", project.path, "--output", output.path, "--progress", "--json"],
            model: model)
        #expect(rendered.exitCode == 0)
        let result = try JSONDecoder().decode(
            VideoEditorService.Result.self, from: Data(rendered.stdout.utf8))
        #expect(result.written)
        #expect(result.videoReport?.bytes ?? 0 > 0)
        let lines = rendered.stderr.split(separator: "\n")
        let percentages = try lines.map { line in
            let value = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(value["event"] as? String == "progress")
            return try #require(value["percent"] as? Int)
        }
        #expect(!percentages.isEmpty && percentages.last == 100)
        #expect(percentages == percentages.sorted() && Set(percentages).count == percentages.count)
        let sheet = root.appendingPathComponent("contact-sheet.png")
        let sampled = try await run(
            [
                "edit", "contact-sheet", project.path, "--output", sheet.path, "--time", "0",
                "--json",
            ],
            model: model)
        #expect(sampled.exitCode == 0 && sampled.stderr.isEmpty)
        #expect(StudioImageIO.info(sheet) != nil)
    }

    @Test func relativePathsAndPlanStdinUseCallerContextWithoutChangingWorkerDirectory()
        async throws
    {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        let workerDirectory = FileManager.default.currentDirectoryPath
        let created = try await StudioCLIExecution.run(
            ExtensionCLIRequest(
                arguments: ["edit", "create", "stdin.openscreen", "--json"],
                workingDirectory: root.path),
            model: model)
        #expect(created.exitCode == 0)
        let plan = try JSONEncoder().encode(
            VideoEditPlan(operations: [.rename(title: "Edited from stdin")]))
        let applied = try await StudioCLIExecution.run(
            ExtensionCLIRequest(
                arguments: [
                    "edit", "apply", "stdin.openscreen", "--plan", "-", "--overwrite", "--json",
                ],
                standardInput: plan, workingDirectory: root.path), model: model)
        #expect(applied.exitCode == 0 && applied.stderr.isEmpty)
        #expect(
            try VideoProject.open(root.appendingPathComponent("stdin.openscreen")).title
                == "Edited from stdin")
        #expect(FileManager.default.currentDirectoryPath == workerDirectory)
        #expect(StudioCLIEnvironment.standardInput.isEmpty)
        #expect(StudioCLIEnvironment.workingDirectory.path == "/")
    }

    @Test func callerContextRejectsRemoteRelativeAndOversizedInput() throws {
        for directory in [
            "relative", "https://example.invalid/", "/tmp\u{0}hidden",
        ] {
            #expect(throws: (any Error).self) {
                try ExtensionCLIRequest(arguments: ["tools"], workingDirectory: directory)
            }
        }
        #expect(throws: ExtensionPeerError.self) {
            try ExtensionCLIRequest(
                arguments: ["edit", "apply"],
                standardInput: Data(repeating: 0, count: StudioEditPlanInput.maximumBytes + 1),
                workingDirectory: "/tmp")
        }
    }

    @Test func toolErrorsPreserveOriginalExitStatusAndChannels() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        let reply = try await run(["info", "nonexistent.tool"], model: model)
        #expect(reply.exitCode == 3)
        #expect(reply.stdout.isEmpty)
        #expect(
            reply.stderr
                == "error: no Studio tool called nonexistent.tool\nhint: run `ed studio tools` to see every tool id\n"
        )
        let usage = try await run(["run", "pdf.merge", "--set", "invalid"], model: model)
        #expect(usage.exitCode == 2 && usage.stdout.isEmpty)
        #expect(usage.stderr.contains("--set needs key=value"))
    }

    @Test func originalRecordingStatusAndInvalidOptionsDoNotStartHardwareCapture() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        let reply = try await run(["record", "status", "--json"], model: model)
        if #available(macOS 15.0, *) {
            #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
            let value = try #require(
                try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
            #expect(value["recording"] as? Bool == false)
            #expect(value["changed"] as? Bool == false)
            #expect(value["sources"] as? [String] == [])
        } else {
            #expect(reply.exitCode == 4 && reply.stdout.isEmpty)
            #expect(reply.stderr.contains("Screen recording needs macOS 15 or later."))
        }
        let invalid = try await run(
            ["record", "start", "--display", "1", "--window", "2"], model: model)
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty)
        #expect(invalid.stderr == "error: pass either --display or --window\n")
        if #available(macOS 15.0, *) { await StudioRecordBridge.shared.shutdown() }
    }

    @Test func disabledModelRejectsExecutionWithoutWriting() async throws {
        let (root, model, suite) = try fixture()
        defer { cleanup(root, model, suite) }
        model.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await run(
                ["edit", "create", root.appendingPathComponent("disabled.openscreen").path],
                model: model)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func longOperationCancellationPropagates() async throws {
        let task = Task {
            try await StudioEditExecution.run(progress: false, json: true) { update in
                update(0.4)
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled delivery returned success.")
        } catch let error as StudioEditInterrupted {
            #expect(error.signal == 2)
        }
    }
}
