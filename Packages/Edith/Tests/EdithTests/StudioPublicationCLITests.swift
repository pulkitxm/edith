import CryptoKit
import Foundation
import MCP
import Testing
@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite(.serialized) struct StudioPublicationCLITests {
    @Test func everyRouteIsRegisteredAndAcceptsJSON() throws {
        for operation in StudioPublicationOperation.allCases {
            let descriptor = try #require(
                UserOperationCatalog.descriptor(id: operation.descriptor.id))
            #expect(descriptor.cli == ["studio", "edit", "publications", operation.rawValue])
            let tool = try #require(
                OperationMCPCatalog.tool(
                    named: "edith_studio_edit_publications_\(operation.rawValue)"))
            #expect(tool.route == descriptor.cli)
            #expect(tool.effect == (operation == .show ? .read : .write))
            let help = try CLIProcessProbe.run(descriptor.cli + ["--help"])
            #expect(help.code == 0)
            #expect(help.stdout.contains("--json"))
        }
    }

    @Test func realCLIAndMCPMoveApprovedProjectSecondWithUnchangedHashes() async throws {
        let fixture = try VideoPublicationTests.Fixture()
        defer { fixture.cleanup() }
        let before = try fixture.projects.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let created = try CLIProcessProbe.run([
            "studio", "edit", "publications", "create", fixture.manifest.path, "--input",
            fixture.input.path, "--json",
        ])
        #expect(created.code == 0, "\(created.stderr)")
        let manifest = try JSONDecoder().decode(
            VideoPublicationService.Result.self, from: Data(created.stdout.utf8)
        ).manifest
        let ids = Array(manifest.items.map(\.projectID).reversed())
        let order = try fixture.order(ids)
        let preview = try await call(
            "reorder", [fixture.manifest.path, "--input", order.path, "--overwrite", "--dry-run"])
        #expect(preview["written"] as? Bool == false)
        #expect(try VideoPublicationService.show(fixture.manifest).items[0].projectID == ids[1])
        let reordered = try await call(
            "reorder", [fixture.manifest.path, "--input", order.path, "--overwrite"])
        #expect(reordered["written"] as? Bool == true)
        let shown = try await call("show", [fixture.manifest.path])
        #expect(
            (shown["items"] as? [[String: Any]])?.compactMap { $0["projectID"] as? String } == ids)
        #expect(try fixture.projects.map { SHA256.hash(data: try Data(contentsOf: $0)) } == before)
        let duplicate = try fixture.order([ids[0], ids[0]])
        let error = try await call(
            "reorder", [fixture.manifest.path, "--input", duplicate.path, "--overwrite"],
            expectingError: true)
        #expect(
            (error["error"] as? [String: Any])?["code"] as? String == "invalid_publication_order")
        let second = fixture.directory.appendingPathComponent("another.json")
        let result = try await call("create", [second.path, "--input", fixture.input.path])
        #expect(result["written"] as? Bool == true)
    }

    private func call(_ operation: String, _ arguments: [String], expectingError: Bool = false)
        async throws -> [String: Any]
    {
        let result = await OperationMCPServer.call(
            CallTool.Parameters(
                name: "edith_studio_edit_publications_\(operation)",
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
