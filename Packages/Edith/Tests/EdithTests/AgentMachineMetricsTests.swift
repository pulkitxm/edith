import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite @MainActor struct AgentMachineMetricsTests {
    @Test func visibleClientReceivesRealDaemonSamplesAndHiddenClientStopsCollection() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let server = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let service = AgentMachineMetricsService(
            lookup: { _ in .local }, makeSession: { _ in server })
        await service.register(on: runtime)
        defer { service.stop() }
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let session = MachineSession(
            machine: .local, local: true, observesWakeRequests: false,
            metricsClient: listener.client())
        let token = UUID()
        #expect(service.activeMachineCount == 0)
        session.setForegroundObservation(token, active: true)
        defer { session.setForegroundObservation(token, active: false) }
        try await eventually { session.sample != nil }
        #expect(session.state.isConnected)
        #expect(!session.collectsMetricsLocally)
        #expect(server.collectsMetricsLocally)
        #expect(service.activeMachineCount == 1)
        #expect(session.sample?.cpu.cores.count == ProcessInfo.processInfo.activeProcessorCount)
        session.setForegroundObservation(token, active: false)
        try await eventually { service.activeMachineCount == 0 }
        #expect(!server.collectsMetricsLocally)
        #expect(server.state.isConnected)
        let timestamp = server.sample?.ts
        try await Task.sleep(for: .milliseconds(2_100))
        #expect(server.sample?.ts == timestamp)
    }

    @Test func twoXPCPeersShareOneCollectorUntilBothLeave() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        var created = 0
        let service = AgentMachineMetricsService(
            lookup: { _ in .local },
            makeSession: { machine in
                created += 1
                return MachineSession(machine: machine, local: true, observesWakeRequests: false)
            })
        await service.register(on: runtime)
        defer { service.stop() }
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let channel = AgentMachineMetricInterest.metrics.channel(machineID: Machine.localID)
        let firstClient = listener.client()
        let secondClient = listener.client()
        let first = try await firstClient.subscribeBusDataAsync(channel: channel) { _ in }
        let second = try await secondClient.subscribeBusDataAsync(channel: channel) { _ in }
        defer { first.cancel(); second.cancel() }
        #expect(created == 1)
        #expect(await runtime.busSubscriberCount(channel: channel) == 2)
        first.cancel()
        try await eventually { await runtime.busSubscriberCount(channel: channel) == 1 }
        #expect(service.activeMachineCount == 1)
        second.cancel()
        try await eventually { service.activeMachineCount == 0 }
    }

    @Test func transportReconnectRestoresDemandWithoutAnotherViewAppearance() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let service = AgentMachineMetricsService(lookup: { _ in .local })
        await service.register(on: runtime)
        defer { service.stop() }
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        let session = MachineSession(
            machine: .local, local: true, observesWakeRequests: false, metricsClient: client)
        let token = UUID()
        session.setForegroundObservation(token, active: true)
        defer { session.setForegroundObservation(token, active: false) }
        try await eventually { session.sample != nil }
        client.reset()
        try await eventually {
            listener.acceptedConnections >= 2 && service.activeMachineCount == 1
        }
        let channel = AgentMachineMetricInterest.metrics.channel(machineID: Machine.localID)
        #expect(await runtime.busSubscriberCount(channel: channel) == 1)
        #expect(session.state.isConnected)
        #expect(!session.collectsMetricsLocally)
    }

    @Test func dockerDemandChangesOnlyDaemonCadenceAndDisconnectReleasesIt() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let server = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        let service = AgentMachineMetricsService(
            lookup: { _ in .local }, makeSession: { _ in server })
        await service.register(on: runtime)
        defer { service.stop() }
        let peer = UUID()
        let channel = AgentMachineMetricInterest.docker.channel(machineID: Machine.localID)
        await runtime.subscribeBus(peer: peer, channel: channel, subscriber: nil)
        #expect(
            server.currentDockerPollInterval == MachineResourcePolicy.foregroundDockerPollInterval)
        #expect(service.activeMachineCount == 1)
        await runtime.forget(peer: peer)
        #expect(
            server.currentDockerPollInterval == MachineResourcePolicy.backgroundDockerPollInterval)
        #expect(!server.collectsMetricsLocally)
        #expect(service.activeMachineCount == 0)
    }

    @Test func missingMachineProducesFailureWithoutStartingACollector() async throws {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let service = AgentMachineMetricsService(lookup: { _ in nil })
        await service.register(on: runtime)
        defer { service.stop() }
        let listener = MachineMetricsTestListener(runtime: runtime)
        defer { listener.stop() }
        let session = MachineSession(
            machine: Machine(name: "Removed", host: "fixture.invalid"), observesWakeRequests: false,
            metricsClient: listener.client())
        let token = UUID()
        session.setForegroundObservation(token, active: true)
        defer { session.setForegroundObservation(token, active: false) }
        try await eventually { session.state.failureMessage != nil }
        #expect(session.state.failureMessage == "This machine is no longer configured.")
        #expect(service.activeMachineCount == 0)
        #expect(service.snapshots().isEmpty)
    }

    @Test func snapshotEncodesConnectionAndContainerStates() throws {
        let session = MachineSession(machine: .local, local: true, observesWakeRequests: false)
        var snapshot = AgentMachineMetricsSnapshot(session: session)
        snapshot.state = .reconnecting(message: "Retrying")
        snapshot.docker = DockerAvailability(
            status: .available(serverVersion: "test", hasCompose: true))
        snapshot.containers = [
            DockerContainer(
                id: "container", names: ["web"], image: "fixture", command: "run", state: .running,
                status: "Up")
        ]
        let roundtrip = try AgentPayload.decode(
            AgentMachineMetricsSnapshot.self, from: AgentPayload.encode(snapshot))
        #expect(roundtrip == snapshot)
    }

    @Test func unrelatedBusTrafficDoesNotStartMachineSampling() async {
        let service = AgentMachineMetricsService(lookup: { _ in
            Issue.record("Unrelated events must not load machine configuration.")
            return .local
        })
        await service.setDemand(channel: "com.pulkit.edith.changed", count: 3)
        await service.setDemand(channel: "machine.metrics.invalid", count: 1)
        #expect(service.activeMachineCount == 0)
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

private final class MachineMetricsTestListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable
{
    private let listener = NSXPCListener.anonymous()
    private let runtime: AgentRuntime
    private let lock = NSLock()
    private var accepted = 0

    var acceptedConnections: Int { lock.withLock { accepted } }

    init(runtime: AgentRuntime) {
        self.runtime = runtime
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func client() -> AgentClient {
        AgentClient(
            connectionFactory: { [self] disconnected, received in
                MachineMetricsTestConnection(
                    endpoint: listener.endpoint, disconnected: disconnected, received: received)
            }, reconnectDelay: 0.02)
    }

    func stop() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
        -> Bool
    {
        lock.withLock { accepted += 1 }
        connection.exportedInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
        let peer = AgentPeer(connection: connection, runtime: runtime)
        connection.exportedObject = peer
        connection.invalidationHandler = { [runtime] in Task { await runtime.forget(peer: peer.id) }
        }
        connection.interruptionHandler = { [runtime] in Task { await runtime.forget(peer: peer.id) }
        }
        connection.resume()
        return true
    }
}

private final class MachineMetricsTestConnection: NSObject, AgentClientConnection,
    EdithAgentSubscriberXPC, @unchecked Sendable
{
    private let connection: NSXPCConnection
    private let received: @Sendable (String, Data) -> Void

    init(
        endpoint: NSXPCListenerEndpoint, disconnected: @escaping @Sendable () -> Void,
        received: @escaping @Sendable (String, Data) -> Void
    ) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        self.received = received
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: EdithAgentXPC.self)
        connection.exportedInterface = NSXPCInterface(with: EdithAgentSubscriberXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = disconnected
        connection.interruptionHandler = disconnected
        connection.resume()
    }

    func remote(onError: @escaping @Sendable (Error) -> Void) throws -> EdithAgentXPC {
        guard let remote = connection.remoteObjectProxyWithErrorHandler(onError) as? EdithAgentXPC
        else { throw AgentError.unavailable }
        return remote
    }

    func topicChanged(topic: String, payload: Data) { received(topic, payload) }
    func invalidate() { connection.invalidate() }
}
