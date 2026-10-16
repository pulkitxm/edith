import DatabaseCore
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import DatabaseExtension

@Suite @MainActor struct DatabaseCLIMCPTests {
    private let initialize =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Synthetic 🧪","version":"1"}}}"#
        + "\n"
    private let catalog = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
    private let connections =
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"database_connections","arguments":{"action":"list"}}}"#
        + "\n"

    @Test func finiteRequestRunsOriginalMCPAndEmitsUnwrappedRepliesAfterEOF() async throws {
        let sender = MCPOwnedSender()
        let reply = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(
                arguments: ["mcp"], standardInput: Data((initialize + catalog + connections).utf8),
                workingDirectory: "/tmp/synthetic-mcp", interactive: true),
            sender: sender, credentials: { throw MCPTestError.credentials })
        #expect(reply.exitCode == 0)
        #expect(reply.stderr.isEmpty)
        let replies = try decode(Data(reply.stdout.utf8))
        #expect(Set(replies.compactMap { $0["id"] as? Int }) == [1, 2, 3])
        #expect(try toolCount(replies) == 10)
        #expect(await sender.requests.count == 1)
    }

    @Test func liveStreamConsumesInitialInputOnceThenFragmentedBytesResizeAndEOF() async throws {
        let sender = MCPOwnedSender()
        let streams = try ExtensionCLIStreams(owner: "database")
        let handle = try start(streams, sender: sender, input: Data(initialize.utf8))
        var sequence: UInt64 = 0
        let resize = try streams.resize(
            .init(handle: handle, sequence: sequence, columns: 80, rows: 24))
        #expect(resize.accepted)
        sequence = resize.nextSequence
        let input = Data((catalog + connections).utf8)
        for offset in stride(from: 0, to: input.count, by: 7) {
            let end = min(offset + 7, input.count)
            let encoded = try JSONEncoder().encode(
                ExtensionCLIStreamWrite(
                    handle: handle, sequence: sequence, data: input.subdata(in: offset..<end),
                    end: end == input.count))
            let ack = try JSONDecoder().decode(
                ExtensionCLIStreamInputAck.self,
                from: streams.invoke(
                    DatabaseCommand.self, operation: "database.cli.stream.write",
                    prefix: "database.cli.stream", payload: encoded))
            #expect(ack.accepted)
            sequence = ack.nextSequence
        }
        let (data, error, frame) = try await finish(streams, handle: handle)
        #expect(frame.state == .completed && frame.exitCode == 0)
        #expect(error.isEmpty)
        let replies = try decode(data)
        #expect(replies.count == 3)
        #expect(Set(replies.compactMap { $0["id"] as? Int }) == [1, 2, 3])
        #expect(try toolCount(replies) == 10)
        #expect(await sender.requests.count == 1)
        #expect(throws: (any Error).self) {
            try streams.write(.init(handle: handle, sequence: sequence, data: Data("late".utf8)))
        }
        await streams.stopAndWait()
    }

    @Test func stopDrainsActualMCPToolAndBlockedInputAndRejectsLateInput() async throws {
        let sender = MCPBlockingSender()
        let streams = try ExtensionCLIStreams(owner: "database")
        let handle = try start(
            streams, sender: sender, input: Data((initialize + connections).utf8))
        let deadline = ContinuousClock.now + .seconds(3)
        while await !sender.started && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await sender.started)
        await streams.stopAndWait()
        #expect(await sender.cancelled)
        #expect(throws: (any Error).self) {
            try streams.write(.init(handle: handle, sequence: 0, data: Data(), end: true))
        }
        #expect(throws: (any Error).self) {
            try streams.read(.init(handle: handle, sequence: 0))
        }
        let next = try ExtensionCLIStreams(owner: "database")
        _ = try start(next, sender: MCPOwnedSender(), input: Data())
        await Task.yield()
        await next.stopAndWait()
    }

    @Test func malformedFinalFrameReportsFailureAndNeverTouchesEngine() async throws {
        let sender = MCPOwnedSender()
        let reply = try await DatabaseCLIExecution.run(
            ExtensionCLIRequest(
                arguments: ["mcp"], standardInput: Data("{\"jsonrpc\":\"2.0\"}".utf8)),
            sender: sender, credentials: { throw MCPTestError.credentials })
        #expect(reply.exitCode != 0)
        #expect(!reply.stderr.isEmpty)
        #expect(reply.stdout.isEmpty)
        #expect(await sender.requests.isEmpty)
    }

    private func start(
        _ streams: ExtensionCLIStreams, sender: any DatabaseBrokerCommandSending,
        input: Data
    ) throws -> ExtensionCLIStreamHandle {
        try DatabaseCLIEnvironment.$resources.withValue(
            DatabaseCLIResources(
                sender: sender, credentials: { throw MCPTestError.credentials },
                runMCP: { try await DatabaseCLIMCP.run() })
        ) {
            try streams.start(
                DatabaseCommand.self,
                request: .init(
                    owner: "database", session: UUID(),
                    request: try ExtensionCLIRequest(
                        arguments: ["mcp"], standardInput: input,
                        workingDirectory: "/tmp/synthetic-mcp", interactive: true), deadline: 5))
        }
    }

    private func finish(_ streams: ExtensionCLIStreams, handle: ExtensionCLIStreamHandle)
        async throws
        -> (Data, Data, ExtensionCLIStreamFrame)
    {
        let deadline = ContinuousClock.now + .seconds(4)
        var sequence: UInt64 = 0
        var output = Data()
        var error = Data()
        while ContinuousClock.now < deadline {
            let frame = try streams.read(.init(handle: handle, sequence: sequence))
            try frame.validate()
            for chunk in frame.chunks {
                if chunk.channel == .stdout {
                    output.append(chunk.data)
                } else {
                    error.append(chunk.data)
                }
            }
            sequence = frame.nextSequence
            if frame.state != .running { return (output, error, frame) }
            try await Task.sleep(for: .milliseconds(5))
        }
        await streams.stopAndWait()
        throw MCPTestError.deadline
    }

    private func decode(_ data: Data) throws -> [[String: Any]] {
        try data.split(separator: 10).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func toolCount(_ replies: [[String: Any]]) throws -> Int {
        let result = try #require(
            replies.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])
        return try #require(result["tools"] as? [[String: Any]]).count
    }
}

private enum MCPTestError: Error { case credentials, deadline }

private actor MCPOwnedSender: DatabaseBrokerCommandSending {
    private(set) var requests: [DatabaseBrokerCommandRequest] = []
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        requests.append(request)
        return .connectionList(
            .success(
                DatabaseConnectionListResult(connections: []),
                metadata: .init(
                    completeness: DatabaseResultCompleteness(state: .complete))))
    }
}

private actor MCPBlockingSender: DatabaseBrokerCommandSending {
    private(set) var started = false
    private(set) var cancelled = false
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        started = true
        do { try await Task.sleep(for: .seconds(60)) } catch { cancelled = true; throw error }
        throw DatabaseBrokerCommandClientError.unavailable
    }
}
