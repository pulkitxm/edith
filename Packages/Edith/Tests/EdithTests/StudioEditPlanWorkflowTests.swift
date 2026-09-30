import CryptoKit
import Foundation
import Testing
@testable import Edith
@testable import EdithCLI

@Suite(.serialized) struct StudioEditPlanWorkflowTests {
    @Test func summaryRevisionGuardsStalePlansAndReturnsCommittedRevision() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: project, title: "First")
        let shown = await CLIProbe.run([
            "studio", "edit", "show", project.path, "--summary", "--json",
        ])
        #expect(shown.code == 0)
        let summary = try StudioCLITests.json(shown.stdout)
        let revision = try #require(summary["revision"] as? String)
        #expect(revision == Self.digest(try Data(contentsOf: project)))
        let plan = VideoEditPlan(operations: [.rename(title: "Second")])
        let preview = try await VideoEditorService.apply(
            plan, to: project, dryRun: true, expectedRevision: revision)
        #expect(preview.revision == revision && preview.sourceRevision == revision)
        let applied = try await VideoEditorService.apply(
            plan, to: project, overwrite: true, expectedRevision: revision)
        #expect(applied.sourceRevision == revision)
        #expect(applied.revision == Self.digest(try Data(contentsOf: project)))
        #expect(applied.revision != revision)
        let original = try Data(contentsOf: project)
        for dryRun in [true, false] {
            do {
                _ = try await VideoEditorService.apply(
                    VideoEditPlan(operations: [.rename(title: "Stale")]),
                    to: project, dryRun: dryRun, overwrite: true, expectedRevision: revision)
                Issue.record("Stale revision was accepted")
            } catch let failure as VideoEditorService.Failure {
                #expect(failure.code == "project_changed")
            }
            #expect(try Data(contentsOf: project) == original)
        }
    }

    @Test func failedBatchReportsItsIndexAndCauseWithoutPartialWrites() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project.openscreen")
        let plan = directory.appendingPathComponent("plan.json")
        _ = try VideoEditorService.create(at: project, title: "Keep")
        let original = try Data(contentsOf: project)
        try JSONEncoder().encode(
            VideoEditPlan(operations: [
                .rename(title: "Temporary"), .remove(clipID: "absent"),
            ])
        ).write(to: plan)
        let failed = await CLIProbe.run([
            "studio", "edit", "apply", project.path, "--plan", plan.path, "--overwrite", "--json",
        ])
        #expect(failed.code == 2 && failed.stdout.isEmpty)
        let error = try #require(try StudioCLITests.json(failed.stderr)["error"] as? [String: Any])
        #expect(error["operationIndex"] as? Int == 1)
        #expect(error["cause"] as? String == "not_found")
        #expect(try Data(contentsOf: project) == original)
    }

    @Test func narrowedSchemaAndBadFieldMessagesAreActionable() async throws {
        let output = await CLIProbe.run([
            "studio", "edit", "schema", "--operation", "trim", "--json",
        ])
        #expect(output.code == 0)
        let schema = try StudioCLITests.json(output.stdout)
        #expect(schema["required"] as? [String] == ["trim"])
        let invalid = await CLIProbe.run([
            "studio", "edit", "schema", "--operation", "typo", "--json",
        ])
        #expect(invalid.code == 2 && invalid.stdout.isEmpty)
        do {
            _ = try VideoEditPlan.decode(
                Data(
                    #"{"version":1,"operations":[{"trim":{"clipID":"shot","start":0,"finish":1}}]}"#
                        .utf8))
            Issue.record("Unknown field was accepted")
        } catch {
            #expect(error.localizedDescription.contains("operations[0].trim"))
            #expect(error.localizedDescription.contains("unknown fields: finish"))
            #expect(error.localizedDescription.contains("missing fields: end"))
        }
    }

    @Test func stdinPlansResolveExplicitMediaBaseAndRespectByteLimit() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let movie = try await VideoEditorServiceTests.movie(in: media)
        let project = directory.appendingPathComponent("project.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Piped plan")
        let plan = VideoEditPlan(operations: [
            .addMedia(path: movie.lastPathComponent, name: "shot")
        ])
        let arguments = [
            "studio", "edit", "apply", project.path, "--plan", "-", "--media-directory", media.path,
            "--overwrite", "--json",
        ]
        let response = try CLIProcessProbe.run(arguments, input: JSONEncoder().encode(plan))
        #expect(response.code == 0, "\(response.stderr)")
        let loaded = try VideoProject.open(project)
        #expect(loaded.assets.first?.url == movie)
        let original = try Data(contentsOf: project)
        for input in [Data(), Data(repeating: 32, count: 4 * 1024 * 1024 + 1)] {
            let rejected = try CLIProcessProbe.run(arguments, input: input)
            #expect(rejected.code == 2 && rejected.stdout.isEmpty, "\(rejected.stderr)")
            #expect(try Data(contentsOf: project) == original)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
