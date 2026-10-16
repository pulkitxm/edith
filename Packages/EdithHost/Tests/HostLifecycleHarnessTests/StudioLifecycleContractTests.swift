import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing
@testable import HostLifecycleHarness

@MainActor @Suite struct StudioLifecycleContractTests {
    @Test func staticMetadataAndUnavailableActionsAreVerifiedWithoutRunningTools() async throws {
        var commands: [String] = []
        try await StudioLifecycleMetadata.verify { command, input in
            commands.append(command)
            return try Self.reply(command, input)
        }
        #expect(
            commands.prefix(4) == [
                "studio.tools.list", "studio.tools.schema", "studio.tools.schema",
                "surface.snapshot",
            ])
        #expect(commands.contains("studio.edit.render"))
        #expect(commands.contains("studio.ui.record.start"))
        #expect(commands.contains("studio.tools.run"))
    }

    @Test(arguments: ["success", "timeout", "foreign-rejection", "cancelled"])
    func forbiddenCommandsMustDeclineExplicitly(mode: String) async {
        await #expect(throws: (any Error).self) {
            try await InertCommandDecline.verify(["effectful"]) { _ in
                switch mode {
                case "success": return Data("{}".utf8)
                case "timeout": throw HostWorkerError.timedOut
                case "cancelled": throw CancellationError()
                default: throw ExtensionPeerError.rejected("Unknown command")
                }
            }
        }
    }

    @Test func peerUnavailableAndItsExactWireRejectionAreAccepted() async throws {
        var count = 0
        try await InertCommandDecline.verify(["first", "second"]) { _ in
            count += 1
            if count == 1 { throw ExtensionPeerError.unavailable }
            throw ExtensionPeerError.rejected(ExtensionPeerError.unavailable.localizedDescription)
        }
        #expect(count == 2)
    }

    @Test(arguments: ["duplicate", "missing", "oversize", "malformed", "schema", "nonzero"])
    func invalidOrEffectfulMetadataCannotPass(mode: String) async {
        await #expect(throws: (any Error).self) {
            try await StudioLifecycleMetadata.verify { command, input in
                if command == "studio.tools.list" {
                    switch mode {
                    case "duplicate":
                        return try JSONSerialization.data(withJSONObject: [
                            Self.tools[0], Self.tools[0],
                        ])
                    case "missing":
                        return try JSONSerialization.data(withJSONObject: [Self.tools[0]])
                    case "oversize": return Data(repeating: 32, count: 524_289)
                    case "malformed": return Data("{}".utf8)
                    default: break
                    }
                }
                if command == "studio.tools.schema", mode == "schema" {
                    var tool = Self.tools[0]; tool["title"] = "Changed"
                    return try JSONSerialization.data(withJSONObject: tool)
                }
                if command == "surface.snapshot", mode == "nonzero" {
                    return try SurfaceSnapshot(
                        providerID: "studio",
                        metrics: [
                            .init("files", "Files", "1"), .init("projects", "Projects", "0"),
                            .init("running", "Running", "0"),
                        ]
                    ).encoded()
                }
                return try Self.reply(command, input)
            }
        }
    }

    private static var tools: [[String: Any]] {
        ["image.resize", "pdf.to-text"].map {
            [
                "id": $0, "title": $0, "family": "synthetic", "inputs": ["file"],
                "options": [[String: Any]](), "requirements": [String](),
            ] as [String: Any]
        }
    }

    private static func reply(_ command: String, _ input: [String: Any]) throws -> Data {
        switch command {
        case "studio.tools.list": return try JSONSerialization.data(withJSONObject: tools)
        case "studio.tools.schema":
            guard
                let tool = tools.first(where: { $0["id"] as? String == input["toolID"] as? String })
            else {
                throw HostWorkerError.invalidResponse
            }
            return try JSONSerialization.data(withJSONObject: tool)
        case "surface.snapshot":
            let request = try SurfaceSnapshotRequest.decode(
                JSONSerialization.data(withJSONObject: input), providerID: "studio")
            #expect(request.target == .home)
            return try SurfaceSnapshot(
                providerID: "studio",
                metrics: [
                    .init("files", "Files", "0"), .init("projects", "Projects", "0"),
                    .init("running", "Running", "0"),
                ]
            ).encoded()
        default: throw ExtensionPeerError.unavailable
        }
    }
}
