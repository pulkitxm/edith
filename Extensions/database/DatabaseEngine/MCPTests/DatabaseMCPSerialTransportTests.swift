import Foundation
import Logging
import MCP
import Testing

@testable import DatabaseMCP

private actor FragmentingDatabaseMCPTransport: Transport {
    nonisolated let logger = Logger(label: "database-mcp-serial-transport-tests")
    private var bytes = Data()

    func connect() async throws {}

    func disconnect() async {}

    func send(_ data: Data) async throws {
        let midpoint = data.count / 2
        bytes.append(data.prefix(midpoint))
        for _ in 0..<20 {
            await Task.yield()
        }
        bytes.append(data.suffix(from: midpoint))
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func output() -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

@Suite struct DatabaseMCPSerialTransportTests {
    @Test func oversizedReplyClosesTransportAndReportsFailure() async throws {
        let base = DatabaseMCPByteTransport(read: { nil }, write: { _ in })
        let transport = DatabaseMCPSerialTransport(base: base, logger: base.logger)
        try await transport.connect()
        await #expect(throws: (any Error).self) {
            try await transport.send(Data(repeating: 65, count: 1_048_577))
        }
        await #expect(throws: (any Error).self) { try await transport.checkCompletion() }
        await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
        await transport.disconnect()
    }

    @Test func serializesConcurrentWritesWithoutByteInterleaving() async throws {
        let base = FragmentingDatabaseMCPTransport()
        let transport = DatabaseMCPSerialTransport(base: base, logger: base.logger)
        try await transport.connect()

        async let first: Void = transport.send(Data("AAAA".utf8))
        async let second: Void = transport.send(Data("BBBB".utf8))
        _ = try await (first, second)

        let output = await base.output()
        #expect(output == "AAAABBBB" || output == "BBBBAAAA")
        await transport.disconnect()
    }
}
