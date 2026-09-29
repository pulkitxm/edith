import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct StudioEditMCPTests {
    @Test func everyHeadlessRouteIsRegisteredAndListed() throws {
        let names = Set(OperationMCPServer.tools.map(\.name))
        for operation in StudioEditOperation.allCases {
            let descriptor = try #require(
                UserOperationCatalog.descriptor(id: operation.descriptor.id))
            #expect(descriptor.cli == ["studio", "edit", operation.rawValue])
            let route = operation.rawValue.replacingOccurrences(of: "-", with: "_")
            let name = "edith_studio_edit_\(route)"
            #expect(names.contains(name))
            let tool = try #require(OperationMCPCatalog.tool(named: name))
            #expect(tool.route == descriptor.cli)
            #expect(
                tool.effect
                    == (["schema", "show", "validate", "list"].contains(operation.rawValue)
                        ? .read : .write))
            #expect(!tool.arguments([], confirm: true).contains("--yes"))
        }
        for operation in StudioDeliveryOperation.allCases {
            let tool = try #require(
                OperationMCPCatalog.tool(named: "edith_studio_edit_render_audio"))
            #expect(tool.route == operation.descriptor.cli)
            #expect(tool.effect == .write)
            #expect(!tool.arguments([], confirm: true).contains("--yes"))
        }
    }

    @Test func nativeDeliveryReceivesTheLongBoundedDeadline() throws {
        let tools = OperationMCPCatalog.tools
        let extended = tools.filter { OperationMCPRunner.executionTimeout(for: $0) != 120 }
        #expect(
            extended.map(\.name) == ["edith_studio_edit_render", "edith_studio_edit_render_audio"])
        #expect(OperationMCPRunner.executionTimeout(for: try #require(extended.first)) == 21600)
        #expect(OperationMCPRunner.maximumOutputBytes == 4 << 20)
        let error = #"{"version":1,"error":{"code":"cancelled","message":"Delivery cancelled."}}"#
        let progress = #"{"version":1,"event":"progress","percent":42}"#
        #expect(
            OperationMCPRunner.deliveryError(
                progress + "\n" + error, for: try #require(extended.first)) == error)
    }

    @Test func mcpCallsCreateApplyValidateRenderAndReturnStructuredErrors() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try await VideoEditorServiceTests.movie(in: directory)
        let project = directory.appendingPathComponent("demo.openscreen")
        let plan = directory.appendingPathComponent("edit.json")
        try JSONEncoder().encode(
            VideoEditPlan(operations: [
                .addMedia(path: source.path, name: "intro"), .speed(clipID: "intro", rate: 2),
            ])
        ).write(to: plan)
        let schema = try await call("schema", [])
        #expect(schema["title"] as? String == "Edith video edit plan v1")
        _ = try await call("create", [project.path, "--title", "Synthetic MCP demo"])
        let before = try Data(contentsOf: project)
        let preview = try await call("apply", [project.path, "--plan", plan.path, "--dry-run"])
        #expect(preview["written"] as? Bool == false)
        #expect(try Data(contentsOf: project) == before)
        _ = try await call("apply", [project.path, "--plan", plan.path, "--overwrite"])
        let shown = try await call("show", [project.path])
        #expect((shown["assets"] as? [[String: Any]])?.count == 1)
        _ = try await call("validate", [project.path])
        let output = directory.appendingPathComponent("demo.mp4")
        let rendered = try await call("render", [project.path, "--output", output.path])
        #expect(rendered["written"] as? Bool == true)
        #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        let frame = directory.appendingPathComponent("demo.png")
        _ = try await call("frame", [project.path, "--time", "0.2", "--output", frame.path])
        #expect((try frame.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        let error = try await call(
            "render", [project.path, "--output", output.path], expectingError: true)
        #expect((error["error"] as? [String: Any])?["code"] as? String == "output_exists")
    }

    private func call(_ operation: String, _ arguments: [String], expectingError: Bool = false)
        async throws -> [String: Any]
    {
        let result = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_studio_edit_\(operation)",
                arguments: ["arguments": .array(arguments.map { .string($0) })]),
            executable: CLIProcessProbe.binary)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            throw VideoEditorService.Failure("invalid_result", "Expected MCP text result.")
        }
        #expect((result.isError == true) == expectingError, "\(text)")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
