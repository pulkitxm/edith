import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct IPCObservationActivationTests {
    @Test func observationsRegisteredBeforeActivationReceiveBusOnlyMessagesOnce() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        let registry = IPCObservationRegistry()
        let values = IPCActivationValues<String>()
        let attempts = IPCActivationValues<Bool>()
        let observation = IPCObservation(fallback: nil) {
            attempts.append(true)
            return try? client.subscribeBus(channel: "fixture.activation") { info in
                if let value = info["value"] as? String { values.append(value) }
            }
        }
        registry.retain(observation)
        defer { registry.release(observation) }
        #expect(await runtime.busChannelCount == 0)
        let state = IPCTransportState()
        IPCTransport.enable(client: client, registry: registry, state: state)
        try await wait { await runtime.busChannelCount == 1 }
        #expect(state.isEnabled)
        registry.activate()
        #expect(attempts.snapshot == [true])
        #expect(await runtime.busChannelCount == 1)
        await runtime.publishBus(
            AgentBusMessage(channel: "fixture.activation", userInfo: ["value": "ready"]),
            from: nil)
        try await wait { values.snapshot.count == 1 }
        #expect(values.snapshot == ["ready"])
        registry.release(observation)
        try await wait { await runtime.busChannelCount == 0 }
    }

    @Test func releaseBeforeActivationNeverSubscribes() {
        let registry = IPCObservationRegistry()
        let attempts = IPCActivationValues<Bool>()
        let observation = IPCObservation(fallback: nil) {
            attempts.append(true)
            return nil
        }
        registry.retain(observation)
        registry.release(observation)
        registry.activate()
        observation.activate()
        #expect(attempts.snapshot.isEmpty)
    }

    @Test func releaseDuringSubscriptionCancelsTheLateNativeConnection() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        let registry = IPCObservationRegistry()
        let entered = IPCActivationValues<Bool>()
        let connected = IPCActivationValues<Bool>()
        let gate = DispatchSemaphore(value: 0)
        let values = IPCActivationValues<String>()
        let observation = IPCObservation(fallback: nil) {
            entered.append(true)
            guard gate.wait(timeout: .now() + 5) == .success else { return nil }
            let subscription = try? client.subscribeBus(channel: "fixture.cancelled") { info in
                if let value = info["value"] as? String { values.append(value) }
            }
            connected.append(subscription != nil)
            return subscription
        }
        registry.retain(observation)
        let activation = Task.detached { registry.activate() }
        do {
            try await wait { !entered.snapshot.isEmpty }
            registry.release(observation)
            gate.signal()
            await activation.value
        } catch {
            registry.release(observation)
            gate.signal()
            await activation.value
            throw error
        }
        #expect(connected.snapshot == [true])
        try await wait { await runtime.busChannelCount == 0 }
        await runtime.publishBus(
            AgentBusMessage(channel: "fixture.cancelled", userInfo: ["value": "late"]),
            from: nil)
        #expect(values.snapshot.isEmpty)
        #expect(registry.count == 0)
    }

    @Test func failedActivationCanRetryAndSuccessDoesNotDuplicateTheSubscription() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        let registry = IPCObservationRegistry()
        let attempts = IPCActivationValues<Bool>()
        let observation = IPCObservation(fallback: nil) {
            attempts.append(true)
            if attempts.snapshot.count == 1 { return nil }
            return try? client.subscribeBus(channel: "fixture.retry") { _ in }
        }
        registry.retain(observation)
        defer { registry.release(observation) }
        registry.activate()
        #expect(await runtime.busChannelCount == 0)
        registry.activate()
        registry.activate()
        #expect(attempts.snapshot.count == 2)
        #expect(await runtime.busChannelCount == 1)
    }

    @Test func releasingAnObservationReleasesItsCapturedOwner() {
        let registry = IPCObservationRegistry()
        let holder = IPCActivationOwner()
        let observation = retainedObservation(holder)
        registry.retain(observation)
        #expect(holder.value != nil)
        registry.release(observation)
        #expect(holder.value == nil)
    }

    private func retainedObservation(_ holder: IPCActivationOwner) -> IPCObservation {
        let owner = IPCActivationValues<Bool>()
        holder.value = owner
        return IPCObservation(fallback: nil) { [owner] in
            withExtendedLifetime(owner) {}
            return nil
        }
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw IPCActivationTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class IPCActivationValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    var snapshot: [Value] { lock.withLock { values } }
    func append(_ value: Value) { lock.withLock { values.append(value) } }
}

private final class IPCActivationOwner {
    weak var value: IPCActivationValues<Bool>?
}

private struct IPCActivationTimeout: Error {}
