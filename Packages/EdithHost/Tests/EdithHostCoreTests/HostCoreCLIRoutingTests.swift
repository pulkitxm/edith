import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreCLIRoutingTests {
    @Test func originalAgentAndReadinessDispatchThroughAuthenticatedCoreSocket() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-dispatch-" + UUID().uuidString)
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.core-" + UUID().uuidString, supportDirectory: root)
        let defaults = try #require(UserDefaults(suiteName: identity.identifier))
        defer {
            defaults.removePersistentDomain(forName: identity.identifier);
            try? FileManager.default.removeItem(at: root)
        }
        let runtime = try HostCoreRuntime(identity: identity)
        let agent = HostCoreAgentCLI(
            backend: .init(
                status: { try HostCoreAgentStatus(snapshot: runtime.snapshot(), cpuPercent: 0) },
                jobs: { try #require(runtime.snapshot().agent).jobs }, restart: {},
                logs: { _ in [] },
                events: { try #require(runtime.snapshot().agent).events },
                run: { job in
                    #expect(job == "storage.inspect"); _ = try await runtime.inspect()
                },
                cancel: { _ in runtime.cancel() }))
        var inspectCalls: [String] = []
        let readiness = HostCoreReadinessCLI(
            backend: .init(
                entries: { [.init(id: "calendar", title: "Calendar")] },
                inspect: { id, operation in
                    inspectCalls.append(operation)
                    return .init(
                        owner: id, id: id, title: "Calendar",
                        state: .init(
                            extensionID: id, phase: .needsSetup, runtimePhase: .installed,
                            summary: "Calendar permission is missing.",
                            issues: [
                                .init(
                                    id: "calendar.permission", title: "Calendar permission",
                                    detail: "Missing synthetic fixture grant.",
                                    recoveryCommand: "ed permissions request calendar")
                            ]),
                        checks: [
                            .init(
                                id: "calendar.permission", title: "Calendar permission",
                                status: .failed,
                                detail: "Missing synthetic fixture grant.",
                                recoveryCommand: "ed permissions request calendar")
                        ])
                },
                setup: { _, _, _ in throw HostCoreCommandFailure("Owning setup is unavailable.") }))
        let core = HostCoreCLIService(
            configuration: try .init(shared: defaults, standard: defaults),
            action: { arguments in
                if arguments.first == "agent" {
                    return try await agent.execute(Array(arguments.dropFirst()))
                }
                return try await readiness.execute(Array(arguments.dropFirst()))
            })
        let server = HostCLIServer(identity: identity) { try await core.execute($0) }
        try server.start()
        defer { server.shutdown(); core.shutdown() }
        let cli = HostCommandCLI(
            version: "synthetic",
            tooling: .init(home: root, executable: root.appendingPathComponent("ed"), path: []),
            invoke: { try await HostCommandCLITransport.invoke($0, identity: identity) })
        let run = await cli.run(["agent", "run", "storage.inspect"])
        #expect(run.stdout == "queued storage.inspect\n" && run.stderr.isEmpty && run.exitCode == 0)
        let jobs = await cli.run(["agent", "jobs", "--json"])
        #expect(jobs.stdout.contains("\"runCount\": 1"))
        for command in ["status", "verify", "doctor"] {
            let reply = await cli.run(["extensions", command, "calendar", "--json"])
            #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
            #expect(reply.stdout.contains("\"verified\": false"))
        }
        #expect(inspectCalls == ["status", "verify", "doctor"])
        let unsupported = await cli.run(["extensions", "setup", "calendar", "--dry-run"])
        #expect(unsupported.exitCode == 4 && unsupported.stdout.isEmpty)
        #expect(unsupported.stderr == "error: Owning setup is unavailable.\n")
        let invalid = await cli.run(["agent", "run"])
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty)
        await runtime.shutdown()
    }

    @Test func combinedShelfBrowserCatalogKeepsExactOriginalOperationPrefixes() async throws {
        let calls = CoreCatalogCalls()
        let registry = try await HostCLIProviderRegistry.load(invoke: { try await calls.invoke($0) }
        )
        #expect(registry.providers.count == 1)
        #expect(registry.providers[0].state.id == "notchShelf")
        let browser = try await registry.execute(
            ["browser", "navigate", "https://synthetic.invalid"],
            invoke: { try await calls.invoke($0) })
        let shelf = try await registry.execute(
            ["shelf", "ls"], invoke: { try await calls.invoke($0) })
        #expect(
            browser.stdout == "browser:navigate:https://synthetic.invalid\n"
                && browser.exitCode == 7)
        #expect(shelf.stdout == "shelf:ls\n" && shelf.exitCode == 0)
        let operations = await calls.operations
        #expect(operations.contains("notchShelf.cli.catalog"))
        #expect(!operations.contains("browser.cli.catalog"))
        #expect(operations.contains("browser.cli") && operations.contains("notchShelf.cli"))
    }

    @Test func typedOptionalAgentRoutesCannotClaimCoreOrForeignDomains() throws {
        let valid = try CoreCatalogCalls.catalog(owner: "herdr", route: ["agent", "tasks", "ls"])
        let catalog = try HostCLIProviderCatalog.decode(valid, owner: "herdr")
        #expect(catalog.allCommands.contains { $0.route == ["agent", "tasks", "ls"] })
        for route in [["agent", "run"], ["agent", "activity"], ["agent", "status"]] {
            let invalid = try CoreCatalogCalls.catalog(owner: "herdr", route: route)
            #expect(throws: (any Error).self) {
                try HostCLIProviderCatalog.decode(invalid, owner: "herdr")
            }
        }
    }
}

private actor CoreCatalogCalls {
    var operations: [String] = []
    func invoke(_ request: HostCLIRequest) throws -> Data {
        if request.action == .ls {
            return try HostCLIJSON.array([
                .object([
                    "id": .string("notchShelf"), "installed": .bool(true),
                    "compatible": .bool(true),
                    "enabled": .bool(true), "running": .bool(true), "version": .string("1"),
                    "disablePending": .bool(false), "removalPending": .bool(false),
                    "processIdentifier": .integer(Int64(getpid())),
                ])
            ]).encoded()
        }
        let operation = try #require(request.operation); operations.append(operation)
        if operation == "notchShelf.cli.catalog" {
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "notchShelf",
                    commands: [
                        .init(
                            route: ["shelf", "ls"], operation: "notchShelf.cli",
                            summary: "Original shelf route."),
                        .init(
                            route: ["browser", "navigate"], operation: "browser.cli",
                            summary: "Original browser route."),
                    ]))
        }
        let context = try JSONDecoder().decode(HostCLIInvocationContext.self, from: request.payload)
        return try JSONEncoder().encode(
            ExtensionCLIReply(
                stdout: (operation == "browser.cli" ? "browser:" : "shelf:")
                    + context.arguments.joined(separator: ":") + "\n", stderr: "",
                exitCode: operation == "browser.cli" ? 7 : 0))
    }
    static func catalog(owner: String, route: [String]) throws -> Data {
        let normal = HostCLIProviderCatalog(
            owner: owner,
            commands: [
                .init(
                    route: [owner, "ls"], operation: owner + ".cli",
                    summary: "Original owner route.")
            ])
        var catalog = try JSONDecoder().decode(HostCLIJSON.self, from: JSONEncoder().encode(normal))
            .object!
        let route = HostCLIProviderCommand(
            route: route, operation: owner + ".agent.cli", summary: "Original agent route.")
        catalog["coreOwner"] = .object([
            "version": .integer(1), "owner": .string(owner),
            "routes": .array([
                try JSONDecoder().decode(HostCLIJSON.self, from: JSONEncoder().encode(route))
            ]),
        ])
        return try HostCLIJSON.object(catalog).encoded()
    }
}
