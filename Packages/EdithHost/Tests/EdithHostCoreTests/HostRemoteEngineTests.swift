import Darwin
import EdithExtensionSupport
import Foundation
import Testing
@testable import EdithHostCore

@MainActor
struct HostRemoteEngineTests {
    @Test func authenticatedReverseCallsKeepPresentationOwnershipAndSeparatePayloadBounds()
        async throws
    {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let server = try endpoint(identity)
        defer { server.invalidate() }
        let presentation = UUID()
        let request = ExtensionEngineRequest(presentationID: presentation, operation: "sample.read")
        await #expect(throws: HostWorkerError.rejected) { try await server.invokeEngine(request) }
        let state = RequestState()
        let payload = try JSONEncoder().encode(
            String(repeating: "Synthetic record ", count: 20_000))
        #expect(payload.count > HostRemoteWire.maximumBytes)
        let channel = try await HostRemoteChannel.connect(
            to: listenerEndpoint(server), executable: identity.executable,
            executeEngine: { request in
                guard request.presentationID == presentation, request.operation == "sample.read"
                else {
                    throw HostWorkerError.rejected
                }
                state.completed += 1
                return payload
            })
        defer { channel.invalidate() }
        #expect(try await server.invokeEngine(request) == payload)
        await #expect(throws: HostWorkerError.rejected) {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.read"))
        }
        await #expect(throws: HostWorkerError.rejected) {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: presentation, operation: "other.read"))
        }
        await #expect(throws: ExtensionEngineError.rejected) {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: presentation, operation: "extension.native.authorize"))
        }
        #expect(state.completed == 1)
    }

    @Test func reverseTimeoutCancellationAndDisconnectCancelOwnedHostWork() async throws {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let server = try endpoint(identity)
        defer { server.invalidate() }
        let state = RequestState()
        let channel = try await HostRemoteChannel.connect(
            to: listenerEndpoint(server), executable: identity.executable,
            executeEngine: { request in
                if request.operation == "sample.hold" {
                    state.active += 1
                    defer { state.active -= 1; state.completed += 1 }
                    try await Task.sleep(for: .seconds(20))
                }
                return Data("{}".utf8)
            })
        defer { channel.invalidate() }
        await #expect(throws: (any Error).self) {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.hold", timeout: 0.05))
        }
        try await wait { state.completed == 1 }
        let cancelled = Task {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.hold"))
        }
        try await wait { state.active == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await wait { state.completed == 2 }
        #expect(state.active == 0)
        #expect(
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.read")) == Data("{}".utf8))
        let disconnected = Task {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.hold"))
        }
        try await wait { state.active == 1 }
        channel.invalidate()
        await #expect(throws: (any Error).self) { try await disconnected.value }
        try await wait { state.completed == 3 }
        #expect(state.active == 0)
    }

    @Test func reverseRequestsEnforceEightPendingCallsAndPreferencesOnlyDeniesEngineAccess()
        async throws
    {
        let identity = try HostRemoteProcessIdentity.read(getpid())
        let denied = try endpoint(identity)
        defer { denied.invalidate() }
        let preferences = try await HostRemoteChannel.connect(
            to: listenerEndpoint(denied), executable: identity.executable)
        defer { preferences.invalidate() }
        await #expect(throws: HostWorkerError.rejected) {
            try await denied.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.write"))
        }
        let server = try endpoint(identity)
        defer { server.invalidate() }
        let state = RequestState()
        let channel = try await HostRemoteChannel.connect(
            to: listenerEndpoint(server), executable: identity.executable,
            executeEngine: { _ in
                state.active += 1
                defer { state.active -= 1; state.completed += 1 }
                try await Task.sleep(for: .seconds(20))
                return Data("{}".utf8)
            })
        defer { channel.invalidate() }
        let tasks = (0..<8).map { _ in
            Task {
                try await server.invokeEngine(
                    ExtensionEngineRequest(
                        presentationID: UUID(), operation: "sample.hold"))
            }
        }
        try await wait { state.active == 8 }
        await #expect(throws: HostWorkerError.rejected) {
            try await server.invokeEngine(
                ExtensionEngineRequest(
                    presentationID: UUID(), operation: "sample.hold"))
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
        try await wait { state.active == 0 }
        #expect(state.completed == 8)
    }

    private func endpoint(_ identity: HostRemoteProcessIdentity) throws -> HostRemoteEndpoint {
        try HostRemoteEndpoint(
            executable: identity.executable,
            requirement:
                "cdhash H\"\(identity.codeHash.map { String(format: "%02x", $0) }.joined())\"",
            execute: { _ in Data() })
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
