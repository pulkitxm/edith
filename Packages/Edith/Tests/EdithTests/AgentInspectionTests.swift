import Foundation
import Testing
import ArgumentParser

@testable import EdithAgent
@testable import EdithCLI
@testable import EdithKit

@Suite struct AgentInspectionTests {
    @Test func commandParsingPreservesArgumentsAfterTheSeparator() throws {
        let command = try AgentTasksExecCommand.parse([
            "--detach", "--json", "--timeout", "12", "--", "/bin/sh", "-c", "exit 7",
        ])
        #expect(command.command == ["/bin/sh", "-c", "exit 7"])
        #expect(command.detach)
        #expect(command.json)
        #expect(command.timeout == 12)
    }

    @Test func cpuShowsTheRecentIntervalAndSupportsMultipleCores() {
        var sampler = AgentCPUUsageSampler(cpuSeconds: 10, uptime: 100)
        #expect(sampler.sample(cpuSeconds: 11, uptime: 105) == 20)
        #expect(sampler.sample(cpuSeconds: 11, uptime: 105.1) == 20)
        #expect(sampler.sample(cpuSeconds: 21, uptime: 110) == 200)
        #expect(sampler.sample(cpuSeconds: 21, uptime: 115) == 0)
    }

    @Test func peersMustHandshakeBeforePerformingOperations() async throws {
        let runtime = AgentRuntime(build: "test", store: nil)
        await runtime.register(operation: "fixture") { _ in Data("ok".utf8) }
        let connection = NSXPCConnection(machServiceName: "com.pulkit.edith.test.unused")
        let peer = AgentPeer(connection: connection, runtime: runtime)
        let before: (Data?, String?) = await withCheckedContinuation { continuation in
            peer.perform(operation: "fixture", payload: Data()) {
                continuation.resume(returning: ($0, $1))
            }
        }
        #expect(before.0 == nil)
        #expect(before.1 == "Handshake required.")
        let handshakeError: String? = await withCheckedContinuation { continuation in
            peer.handshake(peerVersion: AgentService.protocolVersion) { _, error in
                continuation.resume(returning: error)
            }
        }
        #expect(handshakeError == nil)
        let after: (Data?, String?) = await withCheckedContinuation { continuation in
            peer.perform(operation: "fixture", payload: Data()) {
                continuation.resume(returning: ($0, $1))
            }
        }
        #expect(after.0 == Data("ok".utf8))
        peer.handshake(peerVersion: -1) { _, _ in }
        let refused: String? = await withCheckedContinuation { continuation in
            peer.subscribe(topic: AgentTopic.events.rawValue) {
                continuation.resume(returning: $0)
            }
        }
        #expect(refused == "Handshake required.")
        connection.invalidate()
    }
}
