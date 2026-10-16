import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCoreActivityRoutingTests {
    @Test func checkedHiddenHookAloneAcceptsBoundedOwnedPipeInput() async throws {
        let calls = ActivityCalls()
        let pipe = Pipe()
        let flags = fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL)
        let bytes = Data([123, 34, 101, 34, 58, 34, 240, 159, 140, 164, 34, 125])
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()
        let input = try await HostCommandCLI.inputForCommand(
            ["agent", "activity", "hook", "--provider", "synthetic"],
            descriptor: pipe.fileHandleForReading.fileDescriptor,
            invoke: { try await calls.invoke($0) })
        #expect(input == bytes && fcntl(pipe.fileHandleForReading.fileDescriptor, F_GETFL) == flags)
        let reply = try await HostCoreAgentRouteCLI.execute(
            ["agent", "activity", "hook", "--provider", "synthetic"], input: input,
            invoke: { try await calls.invoke($0) })
        #expect(reply.stdout == "owned hook response\n" && reply.exitCode == 0)
        #expect(await calls.inputs == [bytes])
        let rejected = try await HostCoreAgentRouteCLI.execute(
            ["agent", "activity", "status"], input: bytes, invoke: { try await calls.invoke($0) })
        #expect(rejected.exitCode == 4 && rejected.stdout.isEmpty)
        #expect(await calls.inputs == [bytes])
        await #expect(throws: HostCLIError.self) {
            try await HostCoreAgentRouteCLI.execute(
                ["agent", "activity", "hook"],
                input: Data(repeating: 1, count: HostCLIInvocationContext.maximumInputBytes + 1),
                invoke: { try await calls.invoke($0) })
        }
        try pipe.fileHandleForReading.close()
    }

    @Test func hookRejectsChangedOwnerAndCancelledCallerAndUnavailableOwner() async throws {
        let changed = ActivityCalls(mode: .changed)
        await #expect(throws: HostCoreCommandFailure.self) {
            try await HostCoreAgentRouteCLI.execute(
                ["agent", "activity", "hook"], input: Data("{}".utf8),
                invoke: { try await changed.invoke($0) })
        }
        let cancelled = ActivityCalls(mode: .waiting)
        let work = Task {
            try await HostCoreAgentRouteCLI.execute(
                ["agent", "activity", "hook"], input: Data("{}".utf8),
                invoke: { try await cancelled.invoke($0) })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await cancelled.inputs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cancelled.inputs.count == 1)
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        let unavailable = ActivityCalls(mode: .disabled)
        let result = try await HostCoreAgentRouteCLI.execute(
            ["agent", "activity", "status"], invoke: { try await unavailable.invoke($0) })
        #expect(
            result.exitCode == 4 && result.stdout.isEmpty && result.stderr.contains("enable herdr"))
        #expect(await unavailable.inputs.isEmpty)
    }

    @Test func streamRechecksExactLiveOwnerBeforeReturningEveryFrame() async throws {
        let calls = ActivityCalls(mode: .streamChanged)
        await #expect(throws: HostCoreCommandFailure.self) {
            try await HostCoreAgentRouteCLI.execute(
                ["agent", "activity", "hook"], input: Data("{}".utf8),
                invoke: { try await calls.invoke($0) })
        }
        #expect(await calls.streamOperations == ["herdr.agent.cli.start", "herdr.agent.cli.read"])
    }

    @Test func hiddenHookCannotBecomeAnMCPToolOrCompletionCandidate() async throws {
        let calls = ActivityCalls()
        let output = ActivityOutput()
        let mcp = HostMCPCLI(
            version: "synthetic", invoke: { try await calls.invoke($0) },
            send: { try await output.append($0) })
        try await mcp.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"synthetic\",\"version\":\"1\"},\"capabilities\":{}}}"
                    .utf8))
        try await mcp.accept(
            Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
        try await mcp.accept(Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8))
        let tools = try await output.response(2).object?["result"]?.object?["tools"]?.array ?? []
        #expect(tools.contains { $0.object?["name"] == .string("edith_agent_activity_status") })
        #expect(!tools.contains { $0.object?["name"] == .string("edith_agent_activity_hook") })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "synthetic-unused-" + UUID().uuidString)
        let cli = HostCommandCLI(
            version: "synthetic",
            tooling: .init(home: root, executable: root.appendingPathComponent("ed"), path: []),
            invoke: { try await calls.invoke($0) }, commandEnvironment: { [:] })
        let completion = await cli.run([
            "__complete", "--index", "3", "--", "ed", "agent", "activity", "",
        ])
        #expect(completion.exitCode == 0 && completion.stdout == "status\n")
        await mcp.shutdown()
    }
}

private actor ActivityCalls {
    enum Mode { case ordinary, changed, waiting, disabled, streamChanged }
    var mode: Mode
    var enabled: Bool
    var inputs: [Data] = []
    var streamOperations: [String] = []
    var handle: HostCLIStreamHandle?
    init(mode: Mode = .ordinary) { self.mode = mode; enabled = mode != .disabled }
    func invoke(_ request: HostCLIRequest) async throws -> Data {
        if request.action == .ls {
            return try HostCLIJSON.array([
                .object([
                    "id": .string("herdr"), "installed": .bool(true), "compatible": .bool(true),
                    "enabled": .bool(enabled), "running": .bool(enabled),
                    "version": .string("synthetic"), "disablePending": .bool(false),
                    "removalPending": .bool(false), "processIdentifier": .integer(Int64(getpid())),
                ])
            ]).encoded()
        }
        if request.id == "host" { throw HostCLIError.unavailable }
        if request.operation == "herdr.cli.catalog" {
            let routes = [
                HostCLIProviderCommand(
                    route: ["agent", "activity", "status"], operation: "herdr.agent.cli",
                    summary: "Original activity status."),
                HostCLIProviderCommand(
                    route: ["agent", "activity", "hook"], operation: "herdr.agent.cli",
                    summary: "Original hidden hook.", destructive: true,
                    streamOperation: mode == .streamChanged ? "herdr.agent.cli" : nil,
                    streamDeadline: mode == .streamChanged ? 30 : nil, readsInput: true,
                    jsonOutput: false),
            ]
            let help: HostCLIJSON = .object([
                "serializationVersion": .integer(0),
                "command": .object([
                    "commandName": .string("agent"),
                    "subcommands": .array([
                        .object([
                            "commandName": .string("activity"),
                            "subcommands": .array([
                                .object([
                                    "commandName": .string("status"), "shouldDisplay": .bool(true),
                                ]),
                                .object([
                                    "commandName": .string("hook"), "shouldDisplay": .bool(false),
                                ]),
                            ]),
                        ])
                    ]),
                ]),
            ])
            let core = HostCoreOwnerCatalog(
                version: 1, owner: "herdr", agent: nil, readiness: nil, routes: routes,
                parserHelp: help, completionOperation: nil)
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "herdr",
                    commands: [
                        .init(
                            route: ["herdr", "ls"], operation: "herdr.cli", summary: "Owned route.")
                    ], coreOwner: core))
        }
        if request.operation == "herdr.agent.cli.start" {
            streamOperations.append(request.operation!)
            let body = try JSONDecoder().decode(HostCLIJSON.self, from: request.payload)
            let rawSession = try #require(body.object?["session"]?.string)
            let session = try #require(UUID(uuidString: rawSession))
            let handle = HostCLIStreamHandle(owner: "herdr", session: session, token: UUID())
            self.handle = handle
            return try JSONEncoder().encode(handle)
        }
        if request.operation == "herdr.agent.cli.read" {
            streamOperations.append(request.operation!); enabled = false
            return try JSONEncoder().encode(
                HostCLIStreamFrame(
                    handle: #require(handle), sequence: 0, nextSequence: 1,
                    chunks: [.init(sequence: 0, channel: .stdout, data: Data("stale".utf8))],
                    state: .completed, exitCode: 0))
        }
        guard request.operation == "herdr.agent.cli" else {
            throw HostCLIError.rejected("Unexpected operation.")
        }
        let context = try JSONDecoder().decode(HostCLIInvocationContext.self, from: request.payload)
        inputs.append(context.standardInput)
        if mode == .changed { enabled = false }
        if mode == .waiting { try await Task.sleep(for: .seconds(10)) }
        return try JSONEncoder().encode(
            ExtensionCLIReply(stdout: "owned hook response\n", stderr: "", exitCode: 0))
    }
}

private actor ActivityOutput {
    var values: [HostCLIJSON] = []
    func append(_ data: Data) throws {
        values.append(try JSONDecoder().decode(HostCLIJSON.self, from: data))
    }
    func response(_ id: Int) async throws -> HostCLIJSON {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let value = values.first(where: { $0.object?["id"] == .integer(Int64(id)) }) {
                return value
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostWorkerError.timedOut
    }
}
