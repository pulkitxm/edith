import Foundation
import Testing

@testable import Edith
@testable import EdithCLI

@Suite(.serialized) struct StudioFrameSamplingCLITests {
    @Test(arguments: ["coverage", "speed", "alignment", "clock"])
    func unsupportedSamplingReturnsTypedRuntimeErrorsWithoutPublishing(_ reason: String)
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url: URL
        let operations: [VideoEditPlan.Operation]
        let message: String
        if reason == "clock" {
            url = try await VideoFrameSamplingPlanTests.clockProject(in: directory)
            operations = try VideoEditorService.open(url).clips.map {
                .frameSampling(clipID: $0.id, mode: .nearest)
            }
            message = "clocks cannot share an exact phase"
        } else {
            let source = directory.appendingPathComponent("source.mov")
            try await VideoFrameSamplingTests.fixture(
                source, times: VideoFrameSamplingTests.timestamps("oneTwenty"))
            url = directory.appendingPathComponent("edit.openscreen")
            _ = try VideoEditorService.create(at: url, title: "Synthetic sampling errors")
            let added = try await VideoEditorService.apply(
                .init(operations: [
                    .addMedia(path: source.path, name: "shot"),
                    .trim(clipID: "shot", start: 0.4, end: 1.4),
                ]), to: url, overwrite: true)
            let id = try #require(added.aliases["shot"])
            switch reason {
            case "coverage":
                operations = [
                    .trim(clipID: id, start: 4, end: 5), .frameSampling(clipID: id, mode: .nearest),
                ]
                message = "extends beyond available source media"
            case "speed":
                operations = [
                    .speed(clipID: id, rate: 2), .frameSampling(clipID: id, mode: .nearest),
                ]
                message = "speed changes are not supported"
            default:
                operations = [
                    .split(clipID: id, sourceTime: 0.525, rightName: "offGrid"),
                    .frameSampling(clipID: "offGrid", mode: .nearest),
                ]
                message = "must start on an output frame boundary"
            }
        }
        let original = try Data(contentsOf: url)
        let plan = directory.appendingPathComponent("plan.json")
        try JSONEncoder().encode(VideoEditPlan(operations: operations)).write(to: plan)
        let destination = directory.appendingPathComponent("existing.openscreen")
        let existing = Data("existing destination".utf8)
        try existing.write(to: destination)
        for dryRun in [false, true] {
            let result = await CLIProbe.run(
                [
                    "studio", "edit", "apply", url.path, "--plan", plan.path,
                    "--output", destination.path, "--overwrite", "--json",
                ] + (dryRun ? ["--dry-run"] : []))
            #expect(result.code == 1)
            #expect(result.stdout.isEmpty)
            let response = try #require(
                JSONSerialization.jsonObject(with: Data(result.stderr.utf8)) as? [String: Any])
            let error = try #require(response["error"] as? [String: Any])
            #expect(error["code"] as? String == "invalid_frame_sampling")
            #expect((error["message"] as? String)?.contains(message) == true)
            #expect(try Data(contentsOf: url) == original)
            #expect(try Data(contentsOf: destination) == existing)
        }
    }
}
