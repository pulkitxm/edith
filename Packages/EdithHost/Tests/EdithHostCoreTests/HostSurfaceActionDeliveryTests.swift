import Testing

@testable import EdithHostCore

@MainActor struct HostSurfaceActionDeliveryTests {
    private enum Failure: Error, Equatable { case delivery, owner }

    @Test func newAndShowRequireOneAwaitedOwnedDelivery() async throws {
        #expect(HostSurfaceActionDelivery.requiresWindow(providerID: "terminal", actionID: "new"))
        #expect(
            HostSurfaceActionDelivery.requiresWindow(
                providerID: "terminal", actionID: "focus/session"))
        #expect(!HostSurfaceActionDelivery.requiresWindow(providerID: "calendar", actionID: "new"))
        var commands = 0, deliveries = 0
        let gate = Gate()
        var completed = false
        let task = Task {
            let result = try await HostSurfaceActionDelivery.perform(
                validate: {},
                command: {
                    commands += 1; return "selected-generation"
                },
                deliver: {
                    deliveries += 1; await gate.wait()
                })
            completed = true
            return result
        }
        for _ in 0..<100 {
            if gate.waiting { break }
            await Task.yield()
        }
        #expect(gate.waiting && commands == 1 && deliveries == 1 && !completed)
        gate.release()
        #expect(try await task.value == "selected-generation")
        #expect(completed && commands == 1 && deliveries == 1)
    }

    @Test func rejectedDeliveryAndChangedOwnersPropagateToTheInvokingAction() async throws {
        var commands = 0, deliveries = 0
        await #expect(throws: Failure.delivery) {
            try await HostSurfaceActionDelivery.perform(
                validate: {}, command: { commands += 1 },
                deliver: {
                    deliveries += 1; throw Failure.delivery
                })
        }
        #expect(commands == 1 && deliveries == 1)
        var current = true
        await #expect(throws: Failure.owner) {
            try await HostSurfaceActionDelivery.perform(
                validate: { if !current { throw Failure.owner } },
                command: {
                    commands += 1; current = false
                },
                deliver: { deliveries += 1 })
        }
        #expect(commands == 2 && deliveries == 1)
        current = true
        await #expect(throws: Failure.owner) {
            try await HostSurfaceActionDelivery.perform(
                validate: { if !current { throw Failure.owner } },
                command: { commands += 1 },
                deliver: {
                    deliveries += 1; current = false
                })
        }
        #expect(commands == 3 && deliveries == 2)
    }

    @Test func cancellationAfterSelectionCannotAcknowledgeWindowDelivery() async throws {
        let gate = Gate()
        let task = Task {
            try await HostSurfaceActionDelivery.perform(
                validate: {}, command: { "selected-generation" }, deliver: { await gate.wait() })
        }
        for _ in 0..<100 {
            if gate.waiting { break }
            await Task.yield()
        }
        #expect(gate.waiting)
        task.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var waiting: Bool { continuation != nil }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
}
