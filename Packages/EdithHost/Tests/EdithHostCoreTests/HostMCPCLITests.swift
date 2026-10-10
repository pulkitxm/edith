import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostMCPCLITests {
    private func initialize(_ server: HostMCPCLI) async throws {
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"clientInfo\":{\"name\":\"fixture\",\"version\":\"1\"},\"capabilities\":{}}}"
                    .utf8))
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8))
    }

    @Test func stdioFramingUsesRealOwnedPipesAndCancellationWakesIdleRead() async throws {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        defer { for descriptor in input + output { Darwin.close(descriptor) } }
        let io = try HostMCPStdio(input: input[0], output: output[1])
        let data = Data("{\"jsonrpc\":\"2.0\"}\n{\"next\":true}\n".utf8)
        #expect(
            data.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress!, $0.count) } == data.count
        )
        #expect(try await io.receive() == Data("{\"jsonrpc\":\"2.0\"}".utf8))
        #expect(try await io.receive() == Data("{\"next\":true}".utf8))
        try await io.send(Data("{\"result\":{}}".utf8))
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = Darwin.read(output[0], &bytes, bytes.count)
        #expect(Data(bytes.prefix(max(0, count))) == Data("{\"result\":{}}\n".utf8))
        let read = Task { try await io.receive() }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

    @Test func partialFrameEOFIsRejectedAndStdoutCannotContainRawDiagnostics() async throws {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        defer { Darwin.close(input[0]); Darwin.close(output[0]); Darwin.close(output[1]) }
        let io = try HostMCPStdio(input: input[0], output: output[1])
        let data = Data("{\"partial\":".utf8)
        _ = data.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress!, $0.count) }
        Darwin.close(input[1])
        await #expect(throws: HostCLIError.self) { try await io.receive() }
        await #expect(throws: HostCLIError.self) { try await io.send(Data("one\ntwo".utf8)) }
    }

    @Test func outputBackpressureIsCancellableWithoutBlockingInsideWrite() async throws {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        #expect(pipe(&input) == 0 && pipe(&output) == 0)
        defer { for descriptor in input + output { Darwin.close(descriptor) } }
        let io = try HostMCPStdio(input: input[0], output: output[1])
        let sender = Task {
            try await io.send(Data(repeating: 120, count: HostMCPStdio.maximumMessageBytes))
        }
        try await Task.sleep(for: .milliseconds(50))
        sender.cancel()
        await #expect(throws: CancellationError.self) { try await sender.value }
    }

    @Test func nativeDatabaseToolSchemaAndArgumentsRouteOnlyToItsEnabledProvider() async throws {
        let output = MCPOutputFixture()
        let calls = MCPNativeFixture()
        let server = HostMCPCLI(
            version: "1", invoke: { try await calls.invoke($0) },
            send: { try await output.append($0) })
        try await initialize(server)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8))
        let tools = try await output.response(2).object?["result"]?.object?["tools"]?.array
        #expect(tools?.first?.object?["name"] == .string("database_query"))
        #expect(
            tools?.first?.object?["inputSchema"]?.object?["required"] == .strings(["connection_id"])
        )
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"database_query\",\"arguments\":{\"connection_id\":\"synthetic\"}}}"
                    .utf8))
        let result = try await output.response(3).object?["result"]?.object
        #expect(result?["structuredContent"]?.object?["rows"] == .integer(0))
        #expect(await calls.payload()?.object?["connection_id"] == .string("synthetic"))
        await server.shutdown()
    }

    @Test func toolsReflectLiveCatalogsAndConfirmationCannotBeSmuggledInArguments() async throws {
        let fixture = MCPProviderFixture()
        let output = MCPOutputFixture()
        let server = HostMCPCLI(
            version: "1", invoke: { try await fixture.invoke($0) },
            send: { try await output.append($0) })
        try await initialize(server)
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8))
        let list = try await output.response(2)
        #expect(
            list.object?["result"]?.object?["tools"]?.array?.first?.object?["name"]
                == .string("edith_music_remove"))
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_music_remove\",\"arguments\":{\"arguments\":[\"--yes=true\"]}}}"
                    .utf8))
        #expect(try await output.response(3).object?["error"] != nil)
        #expect(await fixture.arguments().isEmpty)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_music_remove\",\"arguments\":{\"arguments\":[\"synthetic\"],\"confirm\":true}}}"
                    .utf8))
        let applied = try await output.response(4)
        #expect(applied.object?["result"]?.object?["isError"] == .bool(false))
        #expect(await fixture.arguments() == ["remove", "--json", "--yes", "synthetic"])
        await fixture.disable()
        try await server.accept(
            Data("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\"}".utf8))
        #expect(
            try await output.response(5).object?["result"]?.object?["tools"]?.array?.isEmpty == true
        )
        await server.shutdown()
    }

    @Test func cancellationStopsToolWorkAndDoesNotEmitLateResponse() async throws {
        let fixture = MCPProviderFixture(wait: true)
        let output = MCPOutputFixture()
        let server = HostMCPCLI(
            version: "1", invoke: { try await fixture.invoke($0) },
            send: { try await output.append($0) })
        try await initialize(server)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"edith_music_remove\"}}"
                    .utf8))
        for _ in 0..<100 where await !fixture.started {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.started)
        try await server.accept(
            Data(
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":9}}"
                    .utf8))
        await server.shutdown()
        #expect(await fixture.cancelled)
        #expect(await !output.hasResponse(9))
    }
}

private actor MCPNativeFixture {
    private var received: HostCLIJSON?
    func payload() -> HostCLIJSON? { received }
    func invoke(_ request: HostCLIRequest) throws -> Data {
        if request.action == .ls {
            return try HostCLIJSON.array([
                .object([
                    "id": .string("database"), "installed": .bool(true), "compatible": .bool(true),
                    "enabled": .bool(true), "running": .bool(true), "version": .string("1"),
                    "disablePending": .bool(false), "removalPending": .bool(false),
                ])
            ]).encoded()
        }
        if request.operation == "database.cli.catalog" {
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "database", commands: [],
                    nativeTools: [
                        .init(
                            name: "database_query", title: "Query", summary: "Query a database",
                            operation: "database.mcp.query",
                            inputSchema: .object([
                                "type": .string("object"), "required": .strings(["connection_id"]),
                            ]))
                    ]))
        }
        guard request.id == "database", request.operation == "database.mcp.query" else {
            throw HostCLIError.rejected("Unsupported fixture operation")
        }
        received = try JSONDecoder().decode(HostCLIJSON.self, from: request.payload)
        return try HostCLIJSON.object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("synthetic protocol result")])
            ]), "structuredContent": .object(["rows": .integer(0)]), "isError": .bool(false),
        ]).encoded()
    }
}

private actor MCPOutputFixture {
    private var values: [HostCLIJSON] = []
    func append(_ data: Data) throws {
        values.append(try JSONDecoder().decode(HostCLIJSON.self, from: data))
    }
    func hasResponse(_ id: Int64) -> Bool { values.contains { $0.object?["id"] == .integer(id) } }
    func response(_ id: Int64) async throws -> HostCLIJSON {
        for _ in 0..<200 {
            if let value = values.first(where: { $0.object?["id"] == .integer(id) }) {
                return value
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HostCLIError.timedOut
    }
}

private actor MCPProviderFixture {
    private var enabled = true
    private var lastArguments: [String] = []
    private let wait: Bool
    private(set) var started = false
    private(set) var cancelled = false
    init(wait: Bool = false) { self.wait = wait }
    func arguments() -> [String] { lastArguments }
    func disable() { enabled = false }
    func invoke(_ request: HostCLIRequest) async throws -> Data {
        if request.action == .ls {
            return try HostCLIJSON.array([
                .object([
                    "id": .string("music"), "installed": .bool(true), "compatible": .bool(true),
                    "enabled": .bool(enabled), "running": .bool(enabled), "version": .string("1"),
                    "disablePending": .bool(false), "removalPending": .bool(false),
                ])
            ]).encoded()
        }
        if request.operation == "music.cli.catalog" {
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "music",
                    commands: [
                        .init(
                            route: ["music", "remove"], operation: "music.cli",
                            summary: "Remove a track", destructive: true)
                    ]))
        }
        guard request.id == "music", request.operation == "music.cli" else {
            throw HostCLIError.rejected("Unsupported fixture operation")
        }
        lastArguments = try JSONDecoder().decode(
            HostCLIInvocationContext.self, from: request.payload
        ).arguments
        started = true
        if wait {
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
        }
        return try JSONEncoder().encode(
            ExtensionCLIReply(stdout: "{\"applied\":true}\n", stderr: "", exitCode: 0))
    }
}
