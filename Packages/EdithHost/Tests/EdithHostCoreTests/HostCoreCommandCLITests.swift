import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreCommandCLITests {
    @Test func authenticatedOriginalCommandPreservesBytesExitEnvironmentAndCallerDirectory()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.start()
        let capture = Capture()
        let reply = await fixture.cli.run(
            [
                "agent", "tasks", "exec", "--timeout", "5", "--", "/bin/sh", "-c",
                "printf 'out\\000tail'; printf 'err\\377' >&2; printf '%s' \"$SYNTHETIC_COMMAND\"; /bin/pwd; exit 7",
            ], streamWrite: { await capture.append($0, $1) })
        #expect(reply.exitCode == 7 && reply.stdout.isEmpty && reply.stderr.isEmpty)
        let output = await capture.output
        #expect(
            output == Data([111, 117, 116, 0, 116, 97, 105, 108])
                + Data(("owned" + fixture.root.path + "\n").utf8))
        #expect(await capture.error == Data([101, 114, 114, 255]))
        let json = await fixture.cli.run([
            "agent", "tasks", "exec", "--json", "--", "/bin/sh", "-c",
            "printf 'json'; printf 'stderr' >&2; exit 9",
        ])
        let result = try HostAgentPayload.decode(
            CLICommandResult.self, from: Data(json.stdout.utf8))
        #expect(json.exitCode == 9 && json.stderr.isEmpty)
        #expect(
            result.standardOutputData == Data("json".utf8)
                && result.standardErrorData == Data("stderr".utf8))
        let literal = await fixture.cli.run([
            "agent", "tasks", "exec", "--", "/usr/bin/printf", "%s", "--help",
        ])
        #expect(literal.exitCode == 0 && literal.stdout == "--help")
        await fixture.stop()
    }

    @Test func detachInspectCancelAndCallerCancellationDrainActualOwnedGroups() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.start()
        let args = [
            "agent", "tasks", "exec", "--detach", "--", "/bin/sh", "-c",
            "echo $$ > detached-pid; exec /bin/sleep 120",
        ]
        let detached = await fixture.cli.run(args)
        let id = try #require(
            UUID(uuidString: detached.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let pid = try await fixture.pid("detached-pid")
        #expect(getpgid(pid) == pid && pid != getpid())
        let listed = await fixture.cli.run(["agent", "tasks", "--json"])
        #expect(
            try HostAgentPayload.decode(
                [HostAgentTaskSnapshot].self, from: Data(listed.stdout.utf8)
            ).contains { $0.id == id && !$0.state.isTerminal })
        let cancelled = await fixture.cli.run(["agent", "tasks", "cancel", id.uuidString, "--json"])
        #expect(cancelled.exitCode == 0)
        try await fixture.terminal(id)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let caller = Task {
            await fixture.cli.run([
                "agent", "tasks", "exec", "--", "/bin/sh", "-c",
                "echo $$ > caller-pid; exec /bin/sleep 120",
            ])
        }
        let callerPID = try await fixture.pid("caller-pid")
        caller.cancel()
        let reply = await caller.value
        #expect(reply.exitCode == 130)
        #expect(kill(callerPID, 0) == -1 && errno == ESRCH)
        await fixture.stop()
        #expect(fixture.runtime.snapshot().commandTasks?.allSatisfy { $0.state.isTerminal } == true)
    }

    @Test func originalScheduleCLIUsesPersistedQueueAndRemovalLeavesRunningTaskAlone() async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.start()
        let added = await fixture.cli.run([
            "agent", "schedule", "add", "owned", "--every", "60s", "--cwd", fixture.root.path,
            "--json", "--", "/bin/sh", "-c", "echo $$ > schedule-pid; exec /bin/sleep 120",
        ])
        #expect(added.exitCode == 0 && added.stderr.isEmpty)
        let initial = try HostAgentPayload.decode(
            HostScheduledTaskSnapshot.self, from: Data(added.stdout.utf8))
        let disabled = await fixture.cli.run(["agent", "schedule", "disable", "owned", "--json"])
        #expect(
            try HostAgentPayload.decode(
                HostScheduledTaskSnapshot.self, from: Data(disabled.stdout.utf8)
            ).enabled == false)
        let enabled = await fixture.cli.run(["agent", "schedule", "enable", "owned", "--json"])
        let resumed = try HostAgentPayload.decode(
            HostScheduledTaskSnapshot.self, from: Data(enabled.stdout.utf8))
        #expect(resumed.enabled && resumed.definition == initial.definition)
        let run = await fixture.cli.run(["agent", "schedule", "run", "owned", "--json"])
        let task = try HostAgentPayload.decode(
            HostAgentTaskSnapshot.self, from: Data(run.stdout.utf8))
        let pid = try await fixture.pid("schedule-pid")
        let listed = await fixture.cli.run(["agent", "schedule", "--json"])
        let schedules = try HostAgentPayload.decode(
            [HostScheduledTaskSnapshot].self, from: Data(listed.stdout.utf8))
        #expect(schedules.count == 1 && schedules[0].nextRunAt == resumed.nextRunAt)
        let removed = await fixture.cli.run(["agent", "schedule", "rm", "owned"])
        #expect(removed.stdout == "removed owned\n" && removed.exitCode == 0)
        #expect(kill(pid, 0) == 0)
        let cancel = await fixture.cli.run(["agent", "tasks", "cancel", task.id.uuidString])
        #expect(cancel.exitCode == 0)
        try await fixture.terminal(task.id)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let persistent = await fixture.cli.run([
            "agent", "schedule", "add", "retained", "--cron", "0 * * * *", "--", "/usr/bin/printf",
            "scheduled",
        ])
        #expect(persistent.exitCode == 0)
        await fixture.stop()
        let reopened = try HostCoreRuntime(identity: fixture.identity, environment: { [:] })
        try await reopened.startCommands()
        let values = try HostAgentPayload.decode(
            [HostScheduledTaskSnapshot].self,
            from: await reopened.command(.init(operation: .scheduleList)).encoded())
        #expect(values.map { $0.definition.name } == ["retained"])
        await reopened.shutdown()
    }

    @Test func parserMetadataAndUnavailableDispatcherPreserveHonestResponses() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.start()
        let help = await fixture.cli.run(["agent", "tasks", "exec", "--help"])
        #expect(
            help.exitCode == 0 && help.stdout.contains("--detach")
                && help.stdout.contains("<command>"))
        let guide = await fixture.cli.run(["guide", "--json"])
        #expect(
            guide.exitCode == 0 && guide.stdout.contains("postTerminator")
                && guide.stdout.contains("schedule"))
        let completion = await fixture.cli.run([
            "__complete", "--index", "4", "--", "ed", "agent", "tasks", "exec", "--",
        ])
        #expect(
            completion.exitCode == 0
                && completion.stdout.split(separator: "\n").map(String.init) == [
                    "--detach", "--help", "--json", "--timeout",
                ])
        let invalid = await fixture.cli.run(["agent", "tasks", "exec", "--", "relative-command"])
        #expect(invalid.exitCode == 2 && invalid.stdout.isEmpty)
        let unknown = await fixture.cli.run(["agent", "schedule", "rm", "missing"])
        #expect(unknown.exitCode == 1 && unknown.stdout.isEmpty)
        let catalog = try await fixture.service.execute(
            .init(action: .invoke, id: "host", operation: "host.cli.catalog"))
        #expect(
            try HostCLIProviderCatalog.decode(catalog, owner: "host").commands.contains {
                $0.route == ["agent", "tasks", "exec"] && $0.destructive
            })
        await fixture.stop()
        let unavailable = await fixture.cli.run(["agent", "tasks", "ls"])
        #expect(unavailable.exitCode != 0 && unavailable.stdout.isEmpty)
    }

    @Test func actualCoreMCPPreviewDoesNotSubmitAndConfirmedCallReturnsOriginalResult() async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.start()
        let output = CommandMCPOutput()
        let identity = fixture.identity
        let mcp = HostMCPCLI(
            version: "synthetic",
            invoke: { try await HostCommandCLITransport.invoke($0, identity: identity) },
            send: { try await output.append($0) },
            coreExecute: { try await fixture.cli.execute($0, input: $1) })
        try await mcp.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"synthetic\",\"version\":\"1\"},\"capabilities\":{}}}"
                    .utf8))
        try await mcp.accept(
            Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        func request(_ id: Int, confirm: Bool) throws -> Data {
            try HostCLIJSON.object([
                "jsonrpc": .string("2.0"), "id": .integer(Int64(id)),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string("edith_agent_tasks_exec"),
                    "arguments": .object([
                        "arguments": .strings([
                            "--", "/bin/sh", "-c", "printf 'mcp'; printf 'stderr' >&2; exit 6",
                        ]), "confirm": .bool(confirm),
                    ]),
                ]),
            ]).encoded()
        }
        try await mcp.accept(request(2, confirm: false))
        let preview = try await output.response(2)
        let previewText = try #require(
            preview.object?["result"]?.object?["content"]?.array?.first?.object?["text"]?.string)
        #expect(
            try JSONDecoder().decode(HostCLIJSON.self, from: Data(previewText.utf8)).object?[
                "preview"] == .bool(true))
        let before = await fixture.cli.run(["agent", "tasks", "ls", "--json"])
        #expect(
            try HostAgentPayload.decode(
                [HostAgentTaskSnapshot].self, from: Data(before.stdout.utf8)
            ).isEmpty)
        try await mcp.accept(request(3, confirm: true))
        let actual = try await output.response(3)
        #expect(actual.object?["result"]?.object?["isError"] == .bool(true))
        let text = try #require(
            actual.object?["result"]?.object?["content"]?.array?.first?.object?["text"]?.string)
        let result = try HostAgentPayload.decode(CLICommandResult.self, from: Data(text.utf8))
        #expect(
            result.terminationStatus == 6 && result.standardOutputData == Data("mcp".utf8)
                && result.standardErrorData == Data("stderr".utf8))
        await mcp.shutdown()
        await fixture.stop()
    }

    @MainActor private final class Fixture {
        let root: URL
        let identity: HostIdentity
        let defaults: UserDefaults
        let suite: String
        let runtime: HostCoreRuntime
        let service: HostCoreCLIService
        let server: HostCLIServer
        let cli: HostCommandCLI
        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "core-command-cli-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let resolved = try #require(realpath(directory.path, nil))
            defer { free(resolved) }
            root = URL(fileURLWithPath: String(cString: resolved))
            suite = "com.pulkit.edith.tests.cli-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
            identity = try HostIdentity(identifier: suite, supportDirectory: root)
            runtime = try HostCoreRuntime(identity: identity, environment: { [:] })
            let runtime = runtime
            let routes = HostCLIHelp.routes.filter {
                $0.starts(with: ["agent", "tasks"]) || $0.starts(with: ["agent", "schedule"])
            }.map { route in
                HostCLIProviderCommand(
                    route: route, operation: "host.cli", summary: "Original core command.",
                    destructive: ["exec", "cancel", "add", "rm", "enable", "disable", "run"]
                        .contains(route.last ?? ""))
            }
            service = HostCoreCLIService(
                configuration: try .init(shared: defaults, standard: defaults), commands: routes,
                commandHandler: { try await runtime.command($0).encoded() },
                action: { arguments in
                    try await HostCoreCommandCLI(
                        invoke: {
                            try await runtime.command(.init(operation: $0, payload: $1)).encoded()
                        }, environment: { [:] },
                        workingDirectory: { HostCoreCLIContext.workingDirectory }
                    ).execute(Array(arguments.dropFirst()))
                })
            let service = service
            server = HostCLIServer(identity: identity) { request in
                if request.action == .ls { return try HostCLIJSON.array([]).encoded() }
                return try await service.execute(request)
            }
            let identity = identity
            let root = root
            cli = HostCommandCLI(
                version: "synthetic",
                tooling: .init(home: root, executable: root.appendingPathComponent("ed"), path: []),
                invoke: { try await HostCommandCLITransport.invoke($0, identity: identity) },
                commandWorkingDirectory: { root.path },
                commandEnvironment: { ["SYNTHETIC_COMMAND": "owned"] })
        }
        func start() async throws { try await runtime.startCommands(); try server.start() }
        func stop() async { server.shutdown(); service.shutdown(); await runtime.shutdown() }
        func remove() {
            defaults.removePersistentDomain(forName: suite);
            try? FileManager.default.removeItem(at: root)
        }
        func pid(_ name: String) async throws -> Int32 {
            let file = root.appendingPathComponent(name)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline
            { try await Task.sleep(for: .milliseconds(10)) }
            return try #require(
                Int32(
                    String(contentsOf: file, encoding: .utf8).trimmingCharacters(
                        in: .whitespacesAndNewlines)))
        }
        func terminal(_ id: UUID) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                let result = await cli.run(["agent", "tasks", "inspect", id.uuidString, "--json"])
                let status = try HostAgentPayload.decode(
                    HostAgentTaskStatus.self, from: Data(result.stdout.utf8))
                if status.snapshot.state.isTerminal { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw HostWorkerError.timedOut
        }
    }
}

private actor Capture {
    var output = Data()
    var error = Data()
    func append(_ data: Data, _ stderr: Bool) {
        if stderr { error.append(data) } else { output.append(data) }
    }
}

private actor CommandMCPOutput {
    var responses: [HostCLIJSON] = []
    func append(_ data: Data) throws {
        responses.append(try JSONDecoder().decode(HostCLIJSON.self, from: data))
    }
    func response(_ id: Int) async throws -> HostCLIJSON {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let result = responses.first(where: { $0.object?["id"] == .integer(Int64(id)) }) {
                return result
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostWorkerError.timedOut
    }
}
