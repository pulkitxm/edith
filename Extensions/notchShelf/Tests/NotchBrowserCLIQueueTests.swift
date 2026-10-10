import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchBrowserCLIQueueTests {
    private func input() -> NotchBrowserRemoteRequest {
        .init(
            identity: .init(ownershipID: UUID(), generation: UUID()), displayID: 1,
            presentationID: UUID(), operation: .commandAttach)
    }

    private func snapshot() -> NotchBrowserSnapshot {
        .init(
            attached: false, profile: nil, profiles: [], tabs: [], sync: "idle",
            canReopen: false)
    }

    @Test func onlyCurrentAdmittedPresentationCanTakeAndCompleteRealResult() async throws {
        let queue = NotchBrowserCLIQueue()
        queue.admitted = { _ in true }
        var request = input()
        request.commandLease = try queue.attach(request)
        let task = Task { try await queue.invoke(.status) }
        try await eventually { queue.pendingCount == 1 }
        let command = try #require(queue.take(request).first)
        #expect(command.request == .status)
        request.commandID = command.id
        try queue.validateCommand(request)
        #expect(try queue.take(request).isEmpty)
        var foreign = request
        foreign = .init(
            identity: request.identity, displayID: 2, presentationID: request.presentationID,
            operation: .commandResult, commandLease: request.commandLease,
            commandResult: .init(id: command.id, snapshot: snapshot(), error: nil))
        #expect(throws: (any Error).self) { try queue.complete(foreign) }
        #expect(queue.pendingCount == 1)
        request.commandResult = .init(id: command.id, snapshot: snapshot(), error: nil)
        try queue.complete(request)
        #expect(try await task.value == snapshot())
        #expect(queue.pendingCount == 0)
        #expect(throws: (any Error).self) { try queue.validateCommand(request) }
        #expect(throws: (any Error).self) { try queue.complete(request) }
        queue.stop()
    }

    @Test func cancellationDeadlineAndReleaseNeverReportSuccess() async throws {
        let queue = NotchBrowserCLIQueue()
        queue.admitted = { _ in true }
        var request = input()
        request.commandLease = try queue.attach(request)
        let cancelled = Task { try await queue.invoke(.reload(hard: true, tab: nil)) }
        try await eventually { queue.pendingCount == 1 }
        let work = try #require(queue.take(request).first)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(queue.pendingCount == 0)
        request.commandResult = .init(id: work.id, snapshot: snapshot(), error: nil)
        #expect(throws: (any Error).self) { try queue.complete(request) }
        await #expect(throws: (any Error).self) { try await queue.invoke(.status, timeout: 0.02) }
        #expect(queue.pendingCount == 0)
        let closing = Task { try await queue.invoke(.status) }
        try await eventually { queue.pendingCount == 1 }
        queue.release(request.presentationID)
        await #expect(throws: (any Error).self) { try await closing.value }
        #expect(queue.pendingCount == 0)
        queue.stop()
    }

    @Test func expiryPrivacyAndOldCleanupDoNotReviveOrKillReplacement() async throws {
        var now = Date()
        let queue = NotchBrowserCLIQueue(now: { now })
        var admitted = true
        queue.admitted = { _ in admitted }
        var request = input()
        let old = try queue.attach(request)
        request.commandLease = old
        now = now.addingTimeInterval(121)
        #expect(throws: (any Error).self) { try queue.take(request) }
        let next = try queue.attach(request)
        #expect(next.id != old.id)
        #expect(throws: (any Error).self) { try queue.end(request) }
        request.commandLease = next
        #expect(try queue.take(request).isEmpty)
        admitted = false
        #expect(throws: (any Error).self) { try queue.take(request) }
        await #expect(throws: (any Error).self) { try await queue.invoke(.status) }
        queue.stop()
    }

    @Test func closingOldClientCannotRetireNewClientWithSamePresentation() throws {
        let queue = NotchBrowserCLIQueue()
        queue.admitted = { _ in true }
        var old = input()
        old.commandLease = try queue.attach(old)
        var next = old; next.commandLease = nil
        let replacement = try queue.attach(next)
        #expect(replacement.id != old.commandLease?.id)
        #expect(throws: (any Error).self) { try queue.end(old) }
        next.commandLease = replacement
        #expect(try queue.take(next).isEmpty)
        let renewed = try queue.attach(next)
        #expect(renewed.id == replacement.id)
        queue.stop()
    }

    @Test func capacityCurrentPrivacyAndStopDrainEveryOwnedWaiter() async throws {
        let queue = NotchBrowserCLIQueue()
        var allowed = true
        queue.admitted = { _ in allowed }
        var owners: [NotchBrowserRemoteRequest] = []
        for _ in 0..<8 {
            var owner = input()
            owner.commandLease = try queue.attach(owner)
            owners.append(owner)
        }
        #expect(throws: (any Error).self) { try queue.attach(input()) }
        let tasks = (0..<8).map { _ in Task { try await queue.invoke(.status) } }
        try await eventually { queue.pendingCount == 8 }
        await #expect(throws: (any Error).self) { try await queue.invoke(.status) }
        var delivered: NotchBrowserRemoteRequest?
        for var owner in owners {
            if let command = try queue.take(owner).first {
                owner.commandID = command.id; delivered = owner; break
            }
        }
        let current = try #require(delivered)
        try queue.validateCommand(current)
        allowed = false
        #expect(throws: (any Error).self) { try queue.validateCommand(current) }
        for task in tasks { await #expect(throws: (any Error).self) { try await task.value } }
        #expect(queue.pendingCount == 0)
        allowed = true
        var owner = input(); owner.commandLease = try queue.attach(owner)
        let stopped = Task { try await queue.invoke(.status) }
        try await eventually { queue.pendingCount == 1 }
        queue.stop()
        await #expect(throws: (any Error).self) { try await stopped.value }
        #expect(queue.pendingCount == 0)
        #expect(throws: (any Error).self) { try queue.take(owner) }
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
