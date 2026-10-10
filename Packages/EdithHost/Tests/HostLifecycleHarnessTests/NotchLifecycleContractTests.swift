import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing
@testable import HostLifecycleHarness

@MainActor @Suite struct NotchLifecycleContractTests {
    @Test func metadataAndExplicitDeclinesNeverRequestAController() async throws {
        var operations: [String] = []
        try await NotchLifecycleMetadata.verify { command in
            operations.append(command)
            if command == "notchShelf.cli.catalog" {
                return try JSONSerialization.data(withJSONObject: Self.catalog)
            }
            throw ExtensionPeerError.unavailable
        }
        #expect(operations.first == "notchShelf.cli.catalog")
        #expect(Array(operations.dropFirst()) == NotchLifecycleMetadata.declinedCommands)
        #expect(WorkerLifecycleFixture.inertIDs.count == 13)
        #expect(WorkerLifecycleFixture.inertIDs.contains("keepAwake"))
        #expect(WorkerLifecycleFixture.inertIDs.contains("notchShelf"))
    }

    @Test(arguments: ["success", "timeout", "cancelled", "foreign"])
    func effectfulOrIncompleteDeclinesCannotPass(mode: String) async {
        await #expect(throws: (any Error).self) {
            try await NotchLifecycleMetadata.verify { command in
                if command == "notchShelf.cli.catalog" {
                    return try JSONSerialization.data(withJSONObject: Self.catalog)
                }
                switch mode {
                case "success": return Data("{}".utf8)
                case "timeout": throw HostWorkerError.timedOut
                case "cancelled": throw CancellationError()
                default: throw ExtensionPeerError.rejected("Unknown command")
                }
            }
        }
    }

    @Test(arguments: [
        "owner", "version", "boolean-version", "route", "operation", "stream", "duplicate",
        "missing-root", "deadline", "input", "parser", "parser-route", "empty", "count",
        "malformed", "oversize",
    ])
    func malformedOrForeignCatalogCannotPass(mode: String) throws {
        var catalog = Self.catalog
        var commands = catalog["commands"] as! [[String: Any]]
        switch mode {
        case "owner": catalog["owner"] = "music"
        case "version": catalog["version"] = 2
        case "boolean-version": catalog["version"] = true
        case "route": commands[0]["route"] = ["shelf", "../escape"]
        case "operation": commands[0]["operation"] = "music.cli"
        case "stream": commands[0]["streamOperation"] = "browser.cli"
        case "duplicate": commands.append(commands[0])
        case "missing-root": commands.removeLast()
        case "deadline": commands[0]["timeout"] = 120
        case "input": commands[0]["readsInput"] = true
        case "parser": catalog["parserHelp"] = [["command": ["commandName": "foreign"]]]
        case "parser-route":
            catalog["parserHelp"] = [
                ["command": ["commandName": "shelf", "subcommands": [["commandName": "foreign"]]]],
                ["command": ["commandName": "browser"]],
            ]
        case "empty": commands = []
        case "count": commands = Array(repeating: commands[0], count: 129)
        default: break
        }
        catalog["commands"] = commands
        let bytes =
            mode == "oversize"
            ? Data(repeating: 32, count: 524_289)
            : mode == "malformed"
                ? Data("null".utf8)
                : try JSONSerialization.data(withJSONObject: catalog)
        #expect(throws: (any Error).self) { try NotchLifecycleMetadata.validateCatalog(bytes) }
    }

    private static var catalog: [String: Any] {
        [
            "version": 1, "owner": "notchShelf", "acceptsInput": true, "settings": [Any](),
            "commands": ["shelf", "browser"].map { root in
                [
                    "route": [root], "operation": root == "shelf" ? "notch.cli" : "browser.cli",
                    "streamOperation": root == "shelf" ? "notch.cli" : "browser.cli",
                    "streamDeadline": 30, "summary": "Synthetic command", "timeout": 30,
                    "destructive": false, "readsInput": false, "jsonOutput": false,
                ] as [String: Any]
            },
            "parserHelp": ["shelf", "browser"].map { ["command": ["commandName": $0]] },
        ]
    }
}
