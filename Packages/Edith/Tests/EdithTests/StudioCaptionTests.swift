import ArgumentParser
import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct StudioCaptionTests {
    @Test func routesHaveParserTreeAndMCPContracts() throws {
        for operation in StudioCaptionOperation.allCases {
            let route = operation.descriptor.cli
            let tool = try #require(
                OperationMCPCatalog.tool(named: "edith_" + route.joined(separator: "_")))
            #expect(tool.route == route)
            #expect(tool.effect == (operation == .list ? .read : .write))
            let node = try #require(CommandTree.node(at: route))
            #expect(node.arguments.first == .localPath)
            #expect(node.options.contains("--json"))
            if operation == .add || operation == .update {
                #expect(node.optionValues["--start-frame"] == .free)
                #expect(node.optionValues["--end-marker"] == .free)
                #expect(node.optionValues["--fps"] == .free)
            }
        }
        let add = try #require(
            EdRoot.parseAsRoot([
                "studio", "edit", "captions", "add", "demo.openscreen", "--text", "Beat",
                "--start-frame", "30", "--end-frame", "60", "--fps", "30000/1001",
            ]) as? StudioCaptionAdd)
        #expect(add.timing.startFrame == 30 && add.timing.fps == "30000/1001")
        #expect(throws: (any Error).self) {
            try EdRoot.parseAsRoot([
                "studio", "edit", "captions", "list", "demo.openscreen", "--typo",
            ])
        }
    }

    @Test func actualMCPCallsCreateUpdateListRejectAndRemove() async throws {
        let (directory, url, _) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = try await call(
            "add",
            [
                url.path, "--text", "Beat one", "--start-frame", "12", "--end-frame", "24", "--fps",
                "60",
            ])
        let id = try #require(created["captionID"] as? String)
        let caption = try #require((created["captions"] as? [[String: Any]])?.first)
        #expect(caption["clock"] as? String == "output")
        let anchor = try #require(caption["anchor"] as? [String: Any])
        #expect((anchor["start"] as? [String: Any])?["frame"] as? Int == 12)
        let updated = try await call(
            "update", [url.path, id, "--text", "Beat two", "--end-frame", "30", "--fps", "60"])
        #expect(updated["captionID"] as? String == id)
        let listed = try await call("list", [url.path])
        #expect(
            (listed["captions"] as? [[String: Any]])?.first?["content"] as? String == "Beat two")
        let before = try Data(contentsOf: url)
        for arguments in [
            [url.path, id, "--start-frame=-1", "--fps", "60"],
            [url.path, id, "--start-frame", "10", "--start-marker", "marker", "--fps", "60"],
            [url.path, id, "--start-frame", "10", "--fps", "240/0"],
            [url.path, "missing", "--text", "Unknown"],
        ] {
            _ = try await call("update", arguments, expectingError: true)
            #expect(try Data(contentsOf: url) == before)
        }
        _ = try await call("remove", [url.path, "missing"], expectingError: true)
        #expect(try Data(contentsOf: url) == before)
        _ = try await call("remove", [url.path, id, "--dry-run"])
        #expect(try Data(contentsOf: url) == before)
        if let evidence = ProcessInfo.processInfo.environment["EDITH_CAPTION_EVIDENCE"] {
            let result: [String: Any] = [
                "operation": "captions update", "captionID": id, "captions": listed["captions"]!,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: evidence))
        }
        _ = try await call("remove", [url.path, id])
        #expect(try VideoEditorService.listCaptions(url).captions.isEmpty)
    }

    private func call(_ operation: String, _ arguments: [String], expectingError: Bool = false)
        async throws -> [String: Any]
    {
        let result = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_studio_edit_captions_\(operation)",
                arguments: ["arguments": .array(arguments.map { .string($0) })]),
            executable: CLIProcessProbe.binary)
        guard case let .text(text, _, _) = try #require(result.content.first) else {
            throw VideoEditorService.Failure("invalid_result", "Expected JSON result.")
        }
        #expect((result.isError == true) == expectingError, "\(text)")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
