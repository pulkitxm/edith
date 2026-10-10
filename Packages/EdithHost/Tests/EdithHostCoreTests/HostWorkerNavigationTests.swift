import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostWorkerNavigationTests {
    @Test func acknowledgementCompletesOnlyTheMatchingRequest() async throws {
        let configuration = try configuration()
        var sent: HostWorkerNavigationRequest?
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true }, send: { sent = $0 }, cancel: { _ in }
        )
        var completed = false
        let task = Task {
            try await client.request(section: "music"); completed = true
        }
        try await wait { sent != nil }
        #expect(!completed)
        let request = try #require(sent)
        let other = HostWorkerNavigationRequest(configuration: configuration)
        try client.receive(HostWorkerNavigationReply(request: other, ok: true))
        #expect(!completed)
        try client.receive(HostWorkerNavigationReply(request: request, ok: true))
        try await task.value
        #expect(completed)
    }

    @Test func cancellationRejectsTheRequestAndAcceptsItsLateReply() async throws {
        let configuration = try configuration()
        var sent: HostWorkerNavigationRequest?
        var cancellation: HostWorkerNavigationCancel?
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true }, send: { sent = $0 },
            cancel: { cancellation = $0 })
        let task = Task { try await client.request() }
        try await wait { sent != nil }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let request = try #require(sent)
        #expect(cancellation?.token == request.token)
        try client.receive(HostWorkerNavigationReply(request: request, ok: true))
    }

    @Test func deadlineCancelsTheOwningHostRoute() async throws {
        var sent: HostWorkerNavigationRequest?
        var cancellation: HostWorkerNavigationCancel?
        let client = HostWorkerNavigationClient(
            configuration: try configuration(), available: { true }, send: { sent = $0 },
            cancel: { cancellation = $0 })
        await #expect(throws: HostWorkerError.timedOut) {
            try await client.request(timeout: .milliseconds(20))
        }
        #expect(cancellation?.token == sent?.token)
    }

    @Test func forgedReplyCannotCompleteTheOwnedRequest() async throws {
        let configuration = try configuration()
        var sent: HostWorkerNavigationRequest?
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true }, send: { sent = $0 }, cancel: { _ in }
        )
        let task = Task { try await client.request() }
        try await wait { sent != nil }
        let original = try #require(sent)
        let forged = HostWorkerNavigationRequest(
            token: original.token, configuration: try self.configuration(id: "other"))
        #expect(throws: HostWorkerError.invalidResponse) {
            try client.receive(HostWorkerNavigationReply(request: forged, ok: true))
        }
        try client.receive(HostWorkerNavigationReply(request: original, ok: true))
        try await task.value
    }

    @Test func requestLimitAndDisconnectRejectAllPendingCallbacks() throws {
        var completions = 0
        var requests = 0
        let client = HostWorkerNavigationClient(
            configuration: try configuration(), available: { true }, send: { _ in requests += 1 },
            cancel: { _ in })
        for _ in 0..<8 {
            #expect(
                client.navigate([:] as NSDictionary) { error in
                    if error == nil { Issue.record("A rejected request reported success") }
                    completions += 1
                } != nil)
        }
        #expect(
            client.navigate([:] as NSDictionary) { error in
                if error == nil { Issue.record("A rejected request reported success") }
                completions += 1
            } == nil)
        #expect(requests == 8)
        #expect(completions == 1)
        client.invalidate()
        #expect(completions == 9)
        #expect(client.navigate([:] as NSDictionary) { _ in completions += 1 } == nil)
        #expect(completions == 10)
    }

    @Test func disableCancellationLeavesTheClientUsableAfterRecovery() throws {
        let configuration = try configuration()
        var available = true
        var request: HostWorkerNavigationRequest?
        var failures = 0
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { available }, send: { request = $0 },
            cancel: { _ in })
        #expect(
            client.navigate([:] as NSDictionary) { error in
                if error == nil { Issue.record("A rejected request reported success") }
                failures += 1
            } != nil)
        available = false
        client.cancelPending()
        #expect(failures == 1)
        available = true
        var succeeded = false
        #expect(client.navigate([:] as NSDictionary) { error in succeeded = error == nil } != nil)
        try client.receive(HostWorkerNavigationReply(request: try #require(request), ok: true))
        #expect(succeeded)
    }

    @Test func synchronousAcknowledgementDoesNotCompleteTwiceWhenSendingThrows() async throws {
        let configuration = try configuration()
        var client: HostWorkerNavigationClient?
        client = HostWorkerNavigationClient(
            configuration: configuration, available: { true },
            send: { request in
                try client?.receive(HostWorkerNavigationReply(request: request, ok: true))
                throw HostWorkerError.exited
            }, cancel: { _ in })
        try await client?.request()
    }

    @Test func objectiveCBridgeRejectsUnboundedOrUnownedInputs() throws {
        var sent = 0
        var rejected = 0
        let client = HostWorkerNavigationClient(
            configuration: try configuration(), available: { true }, send: { _ in sent += 1 },
            cancel: { _ in })
        let invalid: [NSDictionary] = [
            ["url": "https://example.invalid"], ["section": 7],
            ["section": String(repeating: "a", count: 129)], ["section": "bad/section"],
            ["presentationID": "invalid"], ["location": "home"],
            ["presentationID": UUID().uuidString, "location": "arbitrary"],
            ["relativePath": "/absolute"], ["relativePath": "../escape"],
            ["relativePath": "folder//file"], ["relativePath": "folder\\file"],
            ["relativePath": "https://example.invalid"],
            ["relativePath": String(repeating: "a", count: 4097)],
        ]
        for input in invalid {
            #expect(
                client.navigate(input) { error in
                    if error == nil { Issue.record("A rejected request reported success") }
                    rejected += 1
                } == nil)
        }
        #expect(sent == 0)
        #expect(rejected == invalid.count)
    }

    @Test func relativeMusicFolderAndOwnedPresentationRoundTrip() async throws {
        let configuration = try configuration()
        let presentation = UUID()
        var sent: HostWorkerNavigationRequest?
        let client = HostWorkerNavigationClient(
            configuration: configuration, available: { true }, send: { sent = $0 }, cancel: { _ in }
        )
        let task = Task {
            try await client.request(
                section: "music", relativePath: "Synthetic Library/Album",
                presentationID: presentation, location: "home")
        }
        try await wait { sent != nil }
        let decoded = try JSONDecoder().decode(
            HostWorkerNavigationRequest.self, from: JSONEncoder().encode(try #require(sent)))
        #expect(decoded.relativePath == "Synthetic Library/Album")
        #expect(decoded.presentationID == presentation)
        #expect(decoded.location == "home")
        try decoded.validate(configuration: configuration)
        try client.receive(HostWorkerNavigationReply(request: decoded, ok: true))
        try await task.value
        let other = HostWorkerNavigationRequest(
            configuration: try self.configuration(id: "calendar"), relativePath: "Album")
        #expect(throws: HostWorkerError.invalidResponse) {
            try other.validate(configuration: try self.configuration(id: "calendar"))
        }
    }

    @Test func inactiveRecoveryAndExcessiveDeadlinesNeverSendRequests() async throws {
        for recovery in [false, true] {
            var configuration = try configuration()
            configuration.recoveryOnly = recovery
            var sent = false
            let client = HostWorkerNavigationClient(
                configuration: configuration, available: { recovery }, send: { _ in sent = true },
                cancel: { _ in })
            await #expect(throws: HostWorkerError.rejected) { try await client.request() }
            #expect(!sent)
        }
        let client = HostWorkerNavigationClient(
            configuration: try configuration(), available: { true },
            send: { _ in
                Issue.record("An excessive deadline was sent")
            }, cancel: { _ in })
        await #expect(throws: HostWorkerError.rejected) {
            try await client.request(timeout: .seconds(6))
        }
    }

    private func configuration(id: String = "music") throws -> HostWorkerConfiguration {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.navigation",
            supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
        return HostWorkerConfiguration(identity: identity, extensionID: id, version: "1.0.0")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw HostWorkerError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
