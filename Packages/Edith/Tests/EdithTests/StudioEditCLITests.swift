import Foundation
import Testing
@testable import Edith
@testable import EdithCLI

@Suite(.serialized) struct StudioEditCLITests {
    @Test func commandsCreateApplyShowValidateAndReportErrors() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("demo.openscreen")
        let create = await CLIProbe.run([
            "studio", "edit", "create", project.path, "--title", "Synthetic demo", "--json",
        ])
        #expect(create.code == 0, "\(create.stderr)")
        #expect(try StudioCLITests.json(create.stdout)["written"] as? Bool == true)
        let existing = await CLIProbe.run(["studio", "edit", "create", project.path, "--json"])
        #expect(existing.code == 1)
        #expect(existing.stdout.isEmpty)
        #expect(
            (try StudioCLITests.json(existing.stderr)["error"] as? [String: Any])?["code"]
                as? String == "output_exists")
        let plan = directory.appendingPathComponent("edit.json")
        try JSONEncoder().encode(VideoEditPlan(operations: [.rename(title: "New title")])).write(
            to: plan)
        let before = try Data(contentsOf: project)
        let preview = await CLIProbe.run([
            "studio", "edit", "apply", project.path, "--plan", plan.path, "--dry-run", "--json",
        ])
        #expect(preview.code == 0, "\(preview.stderr)")
        #expect(try StudioCLITests.json(preview.stdout)["written"] as? Bool == false)
        #expect(try Data(contentsOf: project) == before)
        let applied = await CLIProbe.run([
            "studio", "edit", "apply", project.path, "--plan", plan.path, "--overwrite", "--json",
        ])
        #expect(applied.code == 0, "\(applied.stderr)")
        let shown = await CLIProbe.run(["studio", "edit", "show", project.path, "--json"])
        #expect(
            (try StudioCLITests.json(shown.stdout)["project"] as? [String: Any])?["title"]
                as? String == "New title")
        let validation = await CLIProbe.run(["studio", "edit", "validate", project.path, "--json"])
        #expect(validation.code == 0, "\(validation.stderr)")
        let schema = await CLIProbe.run(["studio", "edit", "schema", "--json"])
        #expect(schema.code == 0)
        #expect(
            try StudioCLITests.json(schema.stdout)["title"] as? String == "Edith video edit plan v1"
        )
        try Data(#"{"version":1,"operations":[{"remove":{"clipID":"missing"}}]}"#.utf8).write(
            to: plan)
        let invalid = await CLIProbe.run([
            "studio", "edit", "apply", project.path, "--plan", plan.path, "--overwrite", "--json",
        ])
        #expect(invalid.code == 2)
        #expect(
            (try StudioCLITests.json(invalid.stderr)["error"] as? [String: Any])?["code"] as? String
                == "invalid_operation")
        #expect(invalid.stdout.isEmpty)
    }

    @Test func commandRendersSyntheticMediaAndFrameHeadlessly() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await VideoEditorServiceTests.movie(in: directory)
        let project = directory.appendingPathComponent("demo.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Demo")
        let plan = directory.appendingPathComponent("plan.json")
        try JSONEncoder().encode(
            VideoEditPlan(operations: [.addMedia(path: "synthetic.mov", name: "intro")])
        ).write(to: plan)
        let applied = await CLIProbe.run([
            "studio", "edit", "apply", project.path, "--plan", plan.path, "--overwrite", "--json",
        ])
        #expect(applied.code == 0, "\(applied.stderr)")
        for (command, name, extra) in [
            ("render", "movie.mp4", [String]()), ("frame", "frame.png", ["--time", "0.25"]),
        ] {
            let output = directory.appendingPathComponent(name)
            let run = await CLIProbe.run(
                ["studio", "edit", command, project.path, "--output", output.path, "--json"] + extra
            )
            #expect(run.code == 0, "\(run.stderr)")
            #expect(try StudioCLITests.json(run.stdout)["written"] as? Bool == true)
            #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        }
    }
}
