import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct StudioMarkerCommandTests {
    @Test func routesExposeDeterministicToolsAndReadWriteEffects() throws {
        let names = Set(OperationMCPServer.tools.map(\.name))
        for operation in StudioEditMarkerOperation.allCases {
            let descriptor = try #require(
                UserOperationCatalog.descriptor(id: operation.descriptor.id))
            let name = OperationMCPCatalog.toolName(for: descriptor.cli)
            #expect(names.contains(name))
            let tool = try #require(OperationMCPCatalog.tool(named: name))
            #expect(tool.route == operation.descriptor.cli)
            #expect(tool.effect == ([.analyze, .list, .snap].contains(operation) ? .read : .write))
            #expect(!tool.arguments([], confirm: true).contains("--yes"))
            #expect(
                OperationMCPRunner.executionTimeout(for: tool)
                    == (operation == .analyze ? 300 : 120))
        }
    }

    @Test(arguments: [false, true]) func typedCommandsRoundTripThroughCLIAndMCP(mcp: Bool)
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (project, assetID) = try await VideoMarkerServiceTests.fixture(in: directory)
        let original = try Data(contentsOf: project)
        let analysis = try await call(
            .analyze,
            [
                project.path, "--asset", assetID,
                "--source-in", "1", "--source-out", "3", "--output-start", "10", "--playback-rate",
                "2", "--fps", "30",
            ], mcp: mcp)
        let native = try #require(analysis["analysis"] as? [String: Any])
        #expect((native["transients"] as? [Any])?.count == 6)
        #expect(analysis["samplePositionUnit"] as? String == "source_samples")
        let document = try #require(analysis["markerDocument"] as? [String: Any])
        let mapped = try #require(document["markers"] as? [[String: Any]])
        #expect(mapped.compactMap { $0["frame"] as? Int } == [304, 311, 319, 326])
        let preview = try await call(
            .add,
            [
                project.path, "--frame", "30", "--fps", "30", "--label", "Synthetic cue",
                "--dry-run",
            ], mcp: mcp)
        #expect(preview["written"] as? Bool == false)
        #expect(try Data(contentsOf: project) == original)
        _ = try await call(
            .add, [project.path, "--frame", "30", "--fps", "30", "--label", "Synthetic cue"],
            mcp: mcp)
        let listed = try await call(.list, [project.path], mcp: mcp)
        let entries = try #require(listed["markers"] as? [[String: Any]])
        let id = try #require(entries.first?["id"] as? String)
        #expect(entries.first?["outputSeconds"] as? Double == 1)
        _ = try await call(
            .update,
            [project.path, "--id", id, "--frame", "60", "--fps", "30", "--label", "Moved cue"],
            mcp: mcp)
        let snapped = try await call(
            .snap, [project.path, "--frame", "62", "--fps", "30", "--threshold-frames", "2"],
            mcp: mcp)
        #expect(snapped["outputFrame"] as? Int == 60)
        #expect(snapped["nonDropFrameTimecode"] as? String == "00:00:02:00")
        let output = directory.appendingPathComponent("markers.json")
        let exported = try await call(.export, [project.path, "--output", output.path], mcp: mcp)
        #expect(exported["markerCount"] as? Int == 1)
        _ = try await call(.remove, [project.path, "--id", id], mcp: mcp)
        _ = try await call(.import, [project.path, "--input", output.path], mcp: mcp)
        #expect(try VideoProject.open(project).markers.first?.label == "Moved cue")
        let before = try Data(contentsOf: project)
        let invalid = try await call(.add, [project.path, "--frame", "1"], mcp: mcp, error: true)
        #expect((invalid["error"] as? [String: Any])?["code"] as? String == "invalid_frame_rate")
        _ = try await call(.import, [project.path, "--input", output.path], mcp: mcp, error: true)
        let sidecar = directory.appendingPathComponent("clicks.caf.cursor.json")
        let telemetry = Data("synthetic cursor data".utf8)
        try telemetry.write(to: sidecar)
        _ = try await call(
            .export, [project.path, "--output", sidecar.path, "--overwrite"], mcp: mcp, error: true)
        #expect(try Data(contentsOf: sidecar) == telemetry)
        #expect(try Data(contentsOf: project) == before)
    }

    private func call(
        _ operation: StudioEditMarkerOperation, _ arguments: [String], mcp: Bool,
        error: Bool = false
    ) async throws -> [String: Any] {
        let text: String
        if mcp {
            let result = await OperationMCPServer.call(
                CallTool.Parameters(
                    name: OperationMCPCatalog.toolName(for: operation.descriptor.cli),
                    arguments: ["arguments": .array(arguments.map { .string($0) })]),
                executable: CLIProcessProbe.binary)
            guard case let .text(value, _, _) = try #require(result.content.first) else {
                throw VideoEditorService.Failure("invalid_result", "Expected typed JSON text.")
            }
            #expect((result.isError == true) == error, "\(value)")
            text = value
        } else {
            let result = await CLIProbe.run(operation.descriptor.cli + arguments + ["--json"])
            #expect((result.code != 0) == error, "\(result.stderr)")
            text = error ? result.stderr : result.stdout
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
