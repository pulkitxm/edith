import DatabaseCore
import Foundation
import MCP
import Testing

@testable import DatabaseMCP

@Suite struct DatabaseMCPLifecycleTests {
    @Test func cancellationReachesTheOwnedToolAndStopRejectsLateCalls() async throws {
        let sender = BlockingMCPSender()
        let handler = DatabaseMCPToolHandler(sender: sender)
        let task = Task {
            await handler.callTool(
                .init(name: "database_connections", arguments: ["action": "list"]))
        }
        try await wait(sender, count: 1)
        task.cancel()
        let result = await task.value
        #expect(result.isError == true)
        #expect(await sender.cancelled == 1)
        await handler.shutdownAndWait()
        let late = await handler.callTool(
            .init(name: "database_connections", arguments: ["action": "list"]))
        #expect(late.isError == true)
        #expect(await sender.started == 1)
    }

    @Test func thirtyTwoOwnedCallsAreBoundedAndShutdownDrainsAllOfThem() async throws {
        let sender = BlockingMCPSender()
        let handler = DatabaseMCPToolHandler(sender: sender)
        let tasks = (0..<32).map { _ in
            Task {
                await handler.callTool(
                    .init(name: "database_connections", arguments: ["action": "list"]))
            }
        }
        try await wait(sender, count: 32)
        let extra = await handler.callTool(
            .init(name: "database_connections", arguments: ["action": "list"]))
        #expect(extra.isError == true)
        #expect(await sender.started == 32)
        await handler.shutdownAndWait()
        #expect(await sender.cancelled == 32)
        for task in tasks { #expect(await task.value.isError == true) }
    }

    private func wait(_ sender: BlockingMCPSender, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await sender.started < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await sender.started == count)
    }
}

private actor BlockingMCPSender: DatabaseBrokerCommandSending {
    private(set) var started = 0
    private(set) var cancelled = 0
    func send(_ request: DatabaseBrokerCommandRequest) async throws -> DatabaseBrokerCommandResponse
    {
        started += 1
        do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1; throw error }
        throw DatabaseBrokerCommandClientError.unavailable
    }
}
