import DatabaseCore
import Foundation
import MCP
import Testing

@testable import DatabaseMCP

@Suite struct DatabaseMCPByteTransportTests {
    @Test func fragmentedInputAndEOFWaitForRealCatalogAndOwnedToolReplies() async throws {
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Synthetic 🧪","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"database_connections","arguments":{"action":"list"}}}"#,
        ]
        let bytes = Data((messages.joined(separator: "\n") + "\n").utf8)
        let input = FiniteMCPInput((0..<bytes.count).map { Data([bytes[$0]]) })
        let output = MCPOutput()
        let sender = DatabaseMCPScriptedSender([
            .success(
                .connectionList(
                    .success(
                        DatabaseConnectionListResult(connections: []),
                        metadata: DatabaseMCPFixtures.completeMetadata)))
        ])
        let transport = DatabaseMCPByteTransport(
            read: { await input.read() },
            write: { await output.write($0) })
        try await DatabaseMCPServer(sender: sender).run(transport: transport)
        let replies = try await output.data.split(separator: 10).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        #expect(Set(replies.compactMap { $0["id"] as? Int }) == [1, 2, 3])
        let catalog = try #require(
            replies.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])
        #expect((catalog["tools"] as? [[String: Any]])?.count == 10)
        #expect(await sender.recordedRequests().count == 1)
    }

    @Test func partialFinalMessageAndExcessiveChunksFailClosed() async throws {
        for data in [Data("{\"jsonrpc\":\"2.0\"}".utf8), Data(repeating: 65, count: 16_385)] {
            let input = FiniteMCPInput([data])
            let output = MCPOutput()
            let transport = DatabaseMCPByteTransport(
                read: { await input.read() },
                write: { await output.write($0) })
            try await transport.connect()
            await #expect(throws: (any Error).self) {
                for try await _ in await transport.receive() {}
            }
            await transport.disconnect()
            await #expect(throws: (any Error).self) { try await transport.checkCompletion() }
            #expect(await output.data.isEmpty)
            let serverInput = FiniteMCPInput([data])
            let serverTransport = DatabaseMCPByteTransport(
                read: { await serverInput.read() },
                write: { _ in })
            let sender = DatabaseMCPScriptedSender([])
            await #expect(throws: (any Error).self) {
                try await DatabaseMCPServer(sender: sender).run(transport: serverTransport)
            }
            #expect(await sender.recordedRequests().isEmpty)
        }
    }

    @Test func duplicateActiveIdentifiersAndInvalidBooleanIdentifiersReject() async throws {
        for text in [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n"
                + #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n",
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"# + "\n",
        ] {
            let input = FiniteMCPInput([Data(text.utf8)])
            let transport = DatabaseMCPByteTransport(read: { await input.read() }, write: { _ in })
            try await transport.connect()
            await #expect(throws: (any Error).self) {
                for try await _ in await transport.receive() {}
            }
            await transport.disconnect()
        }
    }

    @Test func disconnectCancelsEOFWaitingForAnUnansweredRequest() async throws {
        let input = FiniteMCPInput([
            Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8) + Data([10])
        ])
        let transport = DatabaseMCPByteTransport(read: { await input.read() }, write: { _ in })
        try await transport.connect()
        var iterator = await transport.receive().makeAsyncIterator()
        #expect(try await iterator.next() != nil)
        await transport.disconnect()
        await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
    }
}

private actor FiniteMCPInput {
    private var chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }
    func read() -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
}

private actor MCPOutput {
    private(set) var data = Data()
    func write(_ bytes: Data) { data.append(bytes) }
}
