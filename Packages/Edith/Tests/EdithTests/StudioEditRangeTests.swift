import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI

@Suite(.serialized) struct StudioEditRangeTests {
    @Test func cliAndMCPDeliverRangesWithoutChangingTheProject() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await VideoDeliveryServiceTests.project(in: directory)
        let original = try Data(contentsOf: project)
        let video = directory.appendingPathComponent("range.mov")
        let response = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_studio_edit_render",
                arguments: [
                    "arguments": .array(
                        [
                            project.path, "--output", video.path, "--codec", "proRes422HQ",
                            "--start-frame", "15", "--end-frame", "45", "--progress",
                        ].map { .string($0) })
                ]), executable: CLIProcessProbe.binary)
        guard case let .text(text, _, _) = try #require(response.content.first) else {
            Issue.record("Missing video range delivery result")
            return
        }
        #expect(response.isError != true, "\(text)")
        let result = try StudioCLITests.json(text)
        #expect(result["written"] as? Bool == true)
        let report = try #require(result["videoReport"] as? [String: Any])
        #expect(report["frameCount"] as? Int == 30)
        #expect(report["duration"] as? Double == 0.5)
        let bounds = try #require(report["range"] as? [String: Any])
        #expect(bounds["startFrame"] as? Int == 15 && bounds["endFrame"] as? Int == 45)
        #expect(
            bounds["frameRateNumerator"] as? Int == 60
                && bounds["frameRateDenominator"] as? Int == 1)
        let output = directory.appendingPathComponent("range.wav")
        let audio = try CLIProcessProbe.run([
            "studio", "edit", "render-audio", project.path, "--output", output.path,
            "--start-frame", "15", "--end-frame", "45", "--json",
        ])
        #expect(audio.code == 0, "\(audio.stderr)")
        let audioReport = try #require(
            StudioCLITests.json(audio.stdout)["audioReport"] as? [String: Any])
        #expect(audioReport["frames"] as? Int == 24000)
        #expect((audioReport["range"] as? [String: Any])?["startFrame"] as? Int == 15)
        #expect(try Data(contentsOf: project) == original)
    }

    @Test func rangeFlagsRejectIncompleteAndInvalidIntervalsAndProtectSources() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try await VideoDeliveryServiceTests.project(in: directory)
        let output = directory.appendingPathComponent("range.mp4")
        let original = Data("previous delivery".utf8)
        try original.write(to: output)
        for flags in [
            ["--start-frame", "1"], ["--end-frame", "4"],
            ["--start-frame", "-1", "--end-frame", "4"],
            ["--start-frame", "4", "--end-frame", "4"],
            ["--start-frame", "0", "--end-frame", "61"],
        ] {
            let invalid = try CLIProcessProbe.run(
                [
                    "studio", "edit", "render", project.path, "--output", output.path,
                    "--overwrite", "--json",
                ] + flags)
            #expect(invalid.code != 0)
            #expect(invalid.stdout.isEmpty)
            #expect(try Data(contentsOf: output) == original)
        }
        for (route, file, extra) in [
            ("render", "synthetic.mov", ["--codec", "proRes422HQ"]),
            ("render-audio", "tone.wav", [String]()),
        ] {
            let source = directory.appendingPathComponent(file)
            let data = try Data(contentsOf: source)
            let protected = try CLIProcessProbe.run(
                [
                    "studio", "edit", route, project.path, "--output", source.path,
                    "--start-frame", "15", "--end-frame", "45", "--overwrite", "--json",
                ] + extra)
            #expect(protected.code != 0)
            #expect(protected.stdout.isEmpty)
            #expect(try Data(contentsOf: source) == data)
        }
    }
}
