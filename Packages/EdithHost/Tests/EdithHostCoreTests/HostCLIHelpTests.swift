import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCLIHelpTests {
    @Test func originalParserShapeIncludesCoreArgumentsAndCheckedProviderHelp() throws {
        let help: HostCLIJSON = .object([
            "serializationVersion": .integer(0),
            "command": .object([
                "commandName": .string("music"),
                "subcommands": .array([
                    .object([
                        "commandName": .string("ls"),
                        "arguments": .array([
                            .object([
                                "kind": .string("option"), "valueName": .string("limit"),
                                "names": .array([
                                    .object(["kind": .string("long"), "name": .string("limit")])
                                ]),
                            ])
                        ]),
                    ])
                ]),
            ]),
        ])
        let catalog = HostCLIProviderCatalog(
            owner: "music",
            commands: [
                .init(route: ["music", "ls"], operation: "music.cli", summary: "Read tracks")
            ],
            parserHelp: [help])
        try catalog.validate(owner: "music")
        let registry = HostCLIProviderRegistry(
            providers: [.init(state: try state("music"), catalog: catalog)], issues: [:])
        let document = try HostCLIHelp.document(version: "fixture", registry: registry)
        #expect(document.object?["serializationVersion"] == .integer(0))
        let commands = document.object?["command"]?.object?["subcommands"]?.array ?? []
        let music = try #require(commands.first { $0.object?["commandName"] == .string("music") })
        #expect(
            music.object?["subcommands"]?.array?.first?.object?["arguments"]?.array?.first?.object?[
                "valueName"] == .string("limit"))
        #expect(document.object?["providerIssues"]?.object?.isEmpty == true)
        #expect(try HostCLIHelp.text(["config", "set"]).contains("<key> <value>"))
        #expect(try HostCLIHelp.text(["app", "check-updates"]).contains("--no-wait"))
        #expect(
            HostGuideCLI.text.contains("## Databases")
                && HostGuideCLI.text.contains("## Quinjet review workspaces"))
        #expect(throws: HostCLIError.self) {
            try HostCLIProviderCatalog(
                owner: "calendar",
                commands: [
                    .init(route: ["calendar"], operation: "calendar.cli", summary: "Calendar")
                ], parserHelp: [help]
            ).validate(owner: "calendar")
        }
    }

    @Test func overlappingSystemFamiliesChooseActualLongestOwnedRoute() async throws {
        let system = HostCLIProviderCatalog(
            owner: "system",
            commands: [.init(route: ["system"], operation: "system.cli", summary: "System tools")])
        let stats = HostCLIProviderCatalog(
            owner: "systemStats",
            commands: [
                .init(
                    route: ["system", "stats"], operation: "systemStats.cli",
                    summary: "Sample system")
            ])
        try system.validate(owner: "system"); try stats.validate(owner: "systemStats")
        let states = [try state("system"), try state("systemStats")]
        let data = try JSONEncoder().encode(states)
        let registry = HostCLIProviderRegistry(
            providers: [
                .init(state: states[0], catalog: system), .init(state: states[1], catalog: stats),
            ], issues: [:])
        let result = try await registry.execute(
            ["system", "stats", "--json"],
            invoke: { request in
                if request.action == .ls { return data }
                #expect(request.id == "systemStats" && request.operation == "systemStats.cli")
                let context = try JSONDecoder().decode(
                    HostCLIInvocationContext.self, from: request.payload)
                #expect(context.arguments == ["stats", "--json"])
                return try JSONEncoder().encode(
                    ExtensionCLIReply(stdout: "sample", stderr: "", exitCode: 0))
            })
        #expect(result.stdout == "sample")
    }

    @Test func declaredCallerInputUsesOnlyItsOwnedPipeAndCancellation() async throws {
        var pipeFDs: [Int32] = [-1, -1]
        #expect(pipe(&pipeFDs) == 0)
        defer { Darwin.close(pipeFDs[0]) }
        let input = Data("synthetic SQL\n".utf8)
        _ = input.withUnsafeBytes { Darwin.write(pipeFDs[1], $0.baseAddress!, $0.count) }
        Darwin.close(pipeFDs[1])
        let stateData = try JSONEncoder().encode([state("database")])
        let catalog = try JSONEncoder().encode(
            HostCLIProviderCatalog(
                owner: "database",
                commands: [
                    .init(
                        route: ["database", "query"], operation: "database.cli", summary: "Query",
                        readsInput: true)
                ], acceptsInput: true))
        let result = try await HostCommandCLI.inputForCommand(
            ["database", "query", "synthetic"], descriptor: pipeFDs[0],
            invoke: { request in
                request.action == .ls ? stateData : catalog
            })
        #expect(result == input)
        let inputDescriptor = pipeFDs[0]
        let task = Task {
            try await HostCommandCLI.inputForCommand(
                ["config", "import", "-"], descriptor: inputDescriptor,
                invoke: { _ in throw HostCLIError.unavailable })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func state(_ id: String) throws -> HostCLIProviderState {
        try JSONDecoder().decode(
            HostCLIProviderState.self,
            from: HostCLIJSON.object([
                "id": .string(id), "installed": .bool(true), "compatible": .bool(true),
                "enabled": .bool(true), "running": .bool(true), "version": .string("1.0.0"),
                "disablePending": .bool(false), "removalPending": .bool(false),
                "processIdentifier": .integer(500),
            ]).encoded())
    }
}
