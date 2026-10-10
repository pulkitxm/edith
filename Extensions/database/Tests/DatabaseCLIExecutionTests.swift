import ArgumentParser
import DatabaseCore
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import DatabaseExtension
@testable import DatabaseEngine

@Suite @MainActor struct DatabaseCLIExecutionTests {
    private let connectionID = "11111111-1111-1111-1111-111111111111"

    @Test func originalCommandGroupsAndNestedMutationRoutesRemainAvailable() throws {
        #expect(try DatabaseCommand.parseAsRoot([]) is DatabaseConnectionsListCommand)
        #expect(
            try DatabaseCommand.parseAsRoot(["connections", "ls"])
                is DatabaseConnectionsListCommand)
        #expect(
            try DatabaseCommand.parseAsRoot(["saved-queries"])
                is DatabaseSavedQueriesListCommand)
        #expect(try DatabaseCommand.parseAsRoot(["mcp"]) is DatabaseMCPCommand)
        let help = DatabaseCommand.helpMessage()
        for group in [
            "connections", "saved-queries", "capabilities", "connect", "disconnect",
            "browse", "query", "mutations", "operations", "pack", "mcp",
        ] {
            #expect(help.contains(group))
        }
        #expect(DatabaseMutationsCommand.configuration.subcommands.count >= 4)
        #expect(DatabaseOperationsCommand.configuration.subcommands.count == 3)
        let catalog = try #require(
            try JSONSerialization.jsonObject(
                with: DatabaseCLIExecution.catalog(Data("{}".utf8))) as? [String: Any])
        let routes = try #require(catalog["commands"] as? [[String: Any]])
        #expect(routes.count == 39)
        #expect(routes.contains { $0["route"] as? [String] == ["database", "mutations", "apply"] })
        #expect(
            routes.contains { $0["route"] as? [String] == ["database", "saved-queries", "save"] })
        #expect(routes.allSatisfy { $0["operation"] as? String == "database.cli" })
        #expect(catalog["acceptsInput"] as? Bool == true)
    }

    @Test func queryUsesFullRequestStdinAndRelativeWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("select 2".utf8).write(to: directory.appendingPathComponent("query.sql"))
        for (arguments, input, expected) in [
            (["query", connectionID, "--json"], Data("select 1".utf8), "select 1"),
            (["query", connectionID, "--json", "--file", "query.sql"], Data(), "select 2"),
        ] {
            let sender = RecordingSender()
            let reply = try await DatabaseCLIExecution.run(
                ExtensionCLIRequest(
                    arguments: arguments, standardInput: input,
                    workingDirectory: directory.path), sender: sender,
                credentials: { throw CredentialAccess.forbidden })
            #expect(reply.exitCode == 4)
            let request = try #require(await sender.requests.first)
            guard case let .query(query) = request else {
                Issue.record("The query was not delivered to the owned engine."); return
            }
            #expect(query.command == expected)
            #expect(query.target.connectionID.rawValue.uuidString.lowercased() == connectionID)
        }
    }

    @Test func malformedInputAndInvalidOptionsNeverReachTheEngine() async throws {
        let sender = RecordingSender()
        for request in [
            try ExtensionCLIRequest(
                arguments: ["query", connectionID],
                standardInput: Data([0xff])),
            try ExtensionCLIRequest(
                arguments: ["query", connectionID, "--limit", "0"],
                standardInput: Data("select 1".utf8)),
        ] {
            let reply = try await DatabaseCLIExecution.run(
                request, sender: sender,
                credentials: { throw CredentialAccess.forbidden })
            #expect(reply.exitCode == 2)
            #expect(reply.stdout.isEmpty)
        }
        #expect(await sender.requests.isEmpty)
    }

    @Test func connectionWithoutPasswordNeverCreatesCredentialStorage() async throws {
        let reply = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(arguments: [
                "connections", "add", "--product", "sqlite",
                "--path", "/tmp/synthetic-database.sqlite", "Synthetic",
            ]),
            sender: RecordingSender(), credentials: { throw CredentialAccess.forbidden })
        #expect(reply.exitCode == 4)
        #expect(!reply.stderr.contains("forbidden"))
    }

    @Test func simultaneousCommandsRetainTheirOwnInputAndContext() async throws {
        let first = try ExtensionCLIRequest(
            arguments: ["mcp"], standardInput: Data("first".utf8),
            workingDirectory: "/tmp/first", interactive: true)
        let second = try ExtensionCLIRequest(
            arguments: ["mcp"], standardInput: Data("second".utf8),
            workingDirectory: "/tmp/second")
        async let a = runContextProbe(first)
        async let b = runContextProbe(second)
        let replies = try await [a, b]
        #expect(replies.allSatisfy { $0.exitCode == 0 && $0.stdout.isEmpty })
    }

    @Test func cancellationDrainsTheOwnedCommandAndAllowsNextRequest() async throws {
        let sender = BlockingSender()
        let task = Task {
            try await DatabaseCLIExecution.run(
                ExtensionCLIRequest(arguments: ["connections", "list"]), sender: sender,
                credentials: { throw CredentialAccess.forbidden })
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while await !sender.started && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await sender.started else {
            task.cancel()
            _ = await task.result
            Issue.record("The owned command did not start before its deadline.")
            return
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await sender.cancelled)
        let next = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(arguments: ["--help"]), sender: RecordingSender(),
            credentials: { throw CredentialAccess.forbidden })
        #expect(next.exitCode == 0)
    }

    @Test func streamStopDrainsTheOwnedSenderAndRejectsLateCommands() async throws {
        let sender = BlockingSender()
        let streams = try ExtensionCLIStreams(owner: "database")
        let request = ExtensionCLIStreamStart(
            owner: "database", session: UUID(),
            request: try ExtensionCLIRequest(arguments: ["connections", "list"]), deadline: 5)
        let handle = try DatabaseCLIEnvironment.$resources.withValue(
            DatabaseCLIResources(
                sender: sender, credentials: { throw CredentialAccess.forbidden },
                runMCP: { throw CredentialAccess.forbidden })
        ) { try streams.start(DatabaseCommand.self, request: request) }
        let deadline = ContinuousClock.now + .seconds(3)
        while await !sender.started && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await sender.started)
        await streams.stopAndWait()
        #expect(await sender.cancelled)
        #expect(throws: (any Error).self) {
            try streams.read(ExtensionCLIStreamRead(handle: handle, sequence: 0))
        }
        #expect(throws: (any Error).self) {
            try streams.start(DatabaseCommand.self, request: request)
        }
    }

    @Test func packManagementCannotMutateOrRestartTheOwningWorker() async throws {
        let sender = RecordingSender()
        for command in ["install", "remove"] {
            let reply = try await DatabaseCLIExecution.run(
                ExtensionCLIRequest(arguments: ["pack", command]), sender: sender,
                credentials: { throw CredentialAccess.forbidden })
            #expect(reply.exitCode == 2)
            #expect(reply.stderr.contains("ed extensions"))
        }
        #expect(await sender.requests.isEmpty)
    }

    @Test func originalQueryAndConnectionRoutesUseRealOwnedSQLiteAndReleaseItsLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { try InMemoryDatabaseSecretStore() },
            adapters: { [SQLiteDatabaseAdapter()] })
        let connection = try DatabaseConnectionDraft(
            displayName: "Synthetic CLI SQLite",
            product: .sqlite, path: root.appendingPathComponent("synthetic.sqlite").path,
            environmentKind: .testing, environmentLabel: "Synthetic",
            environmentProtection: .standard, readOnlyPolicy: .disabled,
            productionPolicy: .standard
        ).definition()
        _ = try await engine.send(.connectionSave(.init(connection: connection)))
        let id = connection.id.rawValue.uuidString
        let connected = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(arguments: ["connect", id, "--json"]), sender: engine,
            credentials: { throw CredentialAccess.forbidden })
        #expect(connected.exitCode == 0)
        let reply = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(
                arguments: ["query", id, "--json"],
                standardInput: Data("SELECT 'synthetic-cli-value' AS result".utf8)),
            sender: engine, credentials: { throw CredentialAccess.forbidden })
        #expect(reply.exitCode == 0)
        #expect(reply.stdout.contains("synthetic-cli-value"))
        #expect(reply.stderr.isEmpty)
        let disconnected = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(arguments: ["disconnect", id, "--json"]), sender: engine,
            credentials: { throw CredentialAccess.forbidden })
        #expect(disconnected.exitCode == 0)
        await engine.shutdown()
        #expect(await engine.isRunning == false)
        let fresh = DatabaseEngine(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { try InMemoryDatabaseSecretStore() },
            adapters: { [SQLiteDatabaseAdapter()] })
        let list = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(arguments: ["connections", "list", "--json"]), sender: fresh,
            credentials: { throw CredentialAccess.forbidden })
        #expect(list.exitCode == 0)
        #expect(list.stdout.contains("Synthetic CLI SQLite"))
        await fresh.shutdown()
    }

    private func runContextProbe(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply {
        try await DatabaseCLIExecution.run(
            request, sender: RecordingSender(),
            credentials: { throw CredentialAccess.forbidden },
            runMCP: {
                try await Task.sleep(for: .milliseconds(25))
                #expect(ExtensionCLIContext.request == request)
                #expect(
                    try DatabaseCLIEnvironment.readQueryText(nil)
                        == String(data: request.standardInput, encoding: .utf8))
                #expect(DatabaseCLIEnvironment.resources != nil)
            })
    }
}

private enum CredentialAccess: Error { case forbidden }

private actor RecordingSender: DatabaseBrokerCommandSending {
    private(set) var requests: [DatabaseBrokerCommandRequest] = []
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        requests.append(request)
        throw DatabaseBrokerCommandClientError.unavailable
    }
}

private actor BlockingSender: DatabaseBrokerCommandSending {
    private(set) var started = false
    private(set) var cancelled = false
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        started = true
        do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true; throw error }
        throw DatabaseBrokerCommandClientError.unavailable
    }
}
