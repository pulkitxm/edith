import Darwin
import Foundation
import Testing
@testable import EdithHostCore

@MainActor
struct HostRemoteChannelTests {
    @Test func actualAnonymousConnectionAuthenticatesAndExchangesBoundedData() async throws {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let server = try endpoint(identity: identity) { command in
            guard command.operation == "echo" else { throw HostWorkerError.rejected }
            return command.payload
        }
        defer { server.invalidate() }
        let channel = try await HostRemoteChannel.connect(
            to: listenerEndpoint(server), executable: identity.executable)
        defer { channel.invalidate() }
        #expect(channel.peer == identity)
        let payload = Data("Synthetic bounded response".utf8)
        let reply = try await channel.request(
            HostRemoteCommand(operation: "echo", payload: payload))
        #expect(reply.payload == payload)
        await #expect(throws: HostWorkerError.rejected) {
            try await channel.request(HostRemoteCommand(operation: "unknown"))
        }
        await #expect(throws: HostWorkerError.invalidResponse) {
            try await channel.request(
                HostRemoteCommand(operation: "echo", payload: Data(repeating: 1, count: 131_072)))
        }
        let next = try await channel.request(HostRemoteCommand(operation: "echo", payload: payload))
        #expect(next.payload == payload)
    }

    @Test func incorrectCallerPathAndSelectedExecutableAreRejected() async throws {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let denied = try HostRemoteEndpoint(
            executable: URL(fileURLWithPath: "/tmp/synthetic-untrusted-host"),
            requirement: requirement(identity), execute: { _ in Data() })
        defer { denied.invalidate() }
        await #expect(throws: (any Error).self) {
            try await HostRemoteChannel.connect(
                to: listenerEndpoint(denied), executable: identity.executable)
        }
        let server = try endpoint(identity: identity) { _ in Data() }
        defer { server.invalidate() }
        await #expect(throws: HostWorkerError.rejected) {
            try await HostRemoteChannel.connect(
                to: listenerEndpoint(server),
                executable: URL(fileURLWithPath: "/tmp/synthetic-wrong-selected-worker"))
        }
    }

    @Test func aDifferentSigningRequirementRejectsBeforeExecution() async throws {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let state = RequestState()
        let server = try HostRemoteEndpoint(
            executable: identity.executable,
            requirement: "cdhash H\"\(String(repeating: "0", count: 40))\"",
            execute: { _ in
                state.completed += 1; return Data()
            })
        defer { server.invalidate() }
        await #expect(throws: (any Error).self) {
            try await HostRemoteChannel.connect(
                to: listenerEndpoint(server), executable: identity.executable)
        }
        #expect(state.completed == 0)
    }

    @Test func timeoutAndCancellationStopOwnedRequestsAndLeaveChannelUsable() async throws {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let state = RequestState()
        let server = try endpoint(identity: identity) { command in
            if command.operation == "hold" {
                state.active += 1
                defer { state.active -= 1; state.completed += 1 }
                try await Task.sleep(for: .seconds(20))
            }
            return Data()
        }
        defer { server.invalidate() }
        let channel = try await HostRemoteChannel.connect(
            to: listenerEndpoint(server), executable: identity.executable)
        defer { channel.invalidate() }
        await #expect(throws: HostWorkerError.timedOut) {
            try await channel.request(
                HostRemoteCommand(operation: "hold"), timeout: .milliseconds(50))
        }
        try await wait { state.completed == 1 }
        #expect(state.active == 0)
        let task = Task { try await channel.request(HostRemoteCommand(operation: "hold")) }
        try await wait { state.active == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await wait { state.completed == 2 }
        #expect(state.active == 0)
        _ = try await channel.request(HostRemoteCommand(operation: "status"))
        channel.invalidate()
        await #expect(throws: HostWorkerError.rejected) {
            try await channel.request(HostRemoteCommand(operation: "status"))
        }
    }

    private func endpoint(
        identity: HostRemoteProcessIdentity, execute: @escaping HostRemoteEndpoint.Execute
    ) throws -> HostRemoteEndpoint {
        try HostRemoteEndpoint(
            executable: identity.executable, requirement: requirement(identity), execute: execute)
    }

    private func requirement(_ identity: HostRemoteProcessIdentity) -> String {
        "cdhash H\"\(identity.codeHash.map { String(format: "%02x", $0) }.joined())\""
    }

    private func listenerEndpoint(_ server: HostRemoteEndpoint) -> NSXPCListenerEndpoint {
        var result: NSXPCListenerEndpoint?
        server.endpoint { result = $0 }
        return result!
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private final class RequestState {
        var active = 0
        var completed = 0
    }
}
