import EdithKit
import Foundation
import Observation

@MainActor
public final class AgentMachineMetricsService {
    public typealias Lookup = @MainActor (UUID) -> Machine?
    public typealias MakeSession = @MainActor (Machine) -> MachineSession
    public typealias Publish = @Sendable (AgentMachineMetricsSnapshot) async -> Void

    private final class Entry {
        let session: MachineSession
        let token = UUID()
        var interests: Set<AgentMachineMetricInterest> = []
        var generation = UUID()
        var publicationTask: Task<Void, Never>?
        var inventoryTask: Task<Void, Never>?
        var lastFailure: String?

        init(session: MachineSession) { self.session = session }
        deinit { publicationTask?.cancel(); inventoryTask?.cancel() }
    }

    private let lookup: Lookup
    private let makeSession: MakeSession
    private let publish: Publish
    private var entries: [UUID: Entry] = [:]
    private var idle: [UUID] = []
    private let retainedIdleSessions = 16
    private var activityTask: Task<Void, Never>?
    private var reportsActive = false

    public init(
        lookup: @escaping Lookup = { id in
            id == Machine.localID ? .local : MachineRegistry.machines().first { $0.id == id }
        },
        makeSession: @escaping MakeSession = {
            MachineSession(
                machine: $0, local: $0.id == Machine.localID, observesWakeRequests: false)
        },
        publish: @escaping Publish = { _ in }
    ) {
        self.lookup = lookup
        self.makeSession = makeSession
        self.publish = publish
    }

    private var runtime: AgentRuntime?

    public func register(on runtime: AgentRuntime) async {
        self.runtime = runtime
        await runtime.registerShutdown(id: "machine.metrics") { [self] in
            await stop()
            await finishActivityUpdates()
        }
        await runtime.register(operation: AgentMachineMetricsRefresh.operation) { [self] payload in
            let request = try AgentPayload.decode(AgentMachineMetricsRefresh.self, from: payload)
            try await refresh(request)
            return Data()
        }
        await runtime.setBusDemandObserver { [weak self, runtime] channel, _ in
            let count = await runtime.busSubscriberCount(channel: channel)
            await self?.setDemand(channel: channel, count: count)
        }
    }

    public var activeMachineCount: Int {
        var count = 0
        for entry in entries.values where !entry.interests.isEmpty { count += 1 }
        return count
    }

    public func snapshotData() throws -> Data {
        try AgentPayload.encode(snapshots())
    }

    public func snapshots() -> [AgentMachineMetricsSnapshot] {
        var snapshots: [AgentMachineMetricsSnapshot] = []
        snapshots.reserveCapacity(entries.count)
        for entry in entries.values {
            snapshots.append(AgentMachineMetricsSnapshot(session: entry.session))
        }
        snapshots.sort { $0.machineID.uuidString < $1.machineID.uuidString }
        return snapshots
    }

    public func setDemand(channel: String, count: Int) async {
        guard let (interest, machineID) = AgentMachineMetricInterest.parse(channel: channel) else {
            return
        }
        if count > 0, entries[machineID] == nil {
            guard let machine = lookup(machineID) else {
                let missing = MachineSession(
                    machine: .missing(id: machineID), observesWakeRequests: false)
                var snapshot = AgentMachineMetricsSnapshot(session: missing)
                snapshot.state = .failed(
                    message: "This machine is no longer configured.", recoverable: false)
                await emit(snapshot)
                return
            }
            entries[machineID] = Entry(session: makeSession(machine))
        }
        guard let entry = entries[machineID] else { return }
        let previous = entry.interests
        if count > 0 { entry.interests.insert(interest) } else { entry.interests.remove(interest) }
        if previous.contains(.docker) != entry.interests.contains(.docker) {
            if entry.interests.contains(.docker) {
                entry.session.beginDockerObservation()
            } else {
                entry.session.endDockerObservation()
            }
        }
        if previous.contains(.speed) != entry.interests.contains(.speed) {
            if entry.interests.contains(.speed) {
                entry.session.beginInternetSpeedObservation()
            } else {
                entry.session.endInternetSpeedObservation()
            }
        }
        entry.session.setForegroundObservation(entry.token, active: !entry.interests.isEmpty)
        updateActivity()
        if entry.interests.isEmpty {
            entry.generation = UUID()
            entry.publicationTask?.cancel()
            entry.publicationTask = nil
            entry.inventoryTask?.cancel()
            entry.inventoryTask = nil
            idle.removeAll { $0 == machineID }
            idle.append(machineID)
            while idle.count > retainedIdleSessions { entries[idle.removeFirst()] = nil }
            return
        }
        idle.removeAll { $0 == machineID }
        if previous.isEmpty {
            entry.generation = UUID()
            await observeAndPublish(machineID: machineID, generation: entry.generation)
        } else if count > 0 {
            await emit(AgentMachineMetricsSnapshot(session: entry.session))
        }
    }

    public func stop() {
        for entry in entries.values {
            entry.generation = UUID()
            entry.publicationTask?.cancel()
            entry.publicationTask = nil
            entry.inventoryTask?.cancel()
            entry.inventoryTask = nil
            if entry.interests.contains(.docker) { entry.session.endDockerObservation() }
            if entry.interests.contains(.speed) { entry.session.endInternetSpeedObservation() }
            entry.interests.removeAll()
            entry.session.setForegroundObservation(entry.token, active: false)
        }
        entries.removeAll()
        idle.removeAll()
        updateActivity()
    }

    func finishActivityUpdates() async { await activityTask?.value }

    private func updateActivity() {
        let count = activeMachineCount
        let active = count > 0
        guard let runtime, reportsActive != active else { return }
        reportsActive = active
        let previous = activityTask
        activityTask = Task {
            await previous?.value
            await runtime.setMachineMetricsActive(active)
            await runtime.record(
                AgentEvent(
                    category: "machines", name: active ? "metrics.started" : "metrics.stopped",
                    message: active
                        ? "Collecting live machine data." : "Stopped live machine collection."))
        }
    }

    private func refresh(_ request: AgentMachineMetricsRefresh) async throws {
        guard let entry = entries[request.machineID], !entry.interests.isEmpty else {
            throw AgentError(.refused, "Open the machine before refreshing its live data.")
        }
        switch request.action {
        case .docker: entry.session.refreshDockerNow()
        case .inventory:
            guard entry.inventoryTask == nil else { return }
            entry.inventoryTask = Task { [weak entry] in
                guard let entry else { return }
                await entry.session.refreshImagesAndVolumes()
                guard !Task.isCancelled else { return }
                entry.inventoryTask = nil
            }
        case .speed: entry.session.refreshInternetSpeed()
        case .reconnect: entry.session.retry()
        }
    }

    private func observeAndPublish(machineID: UUID, generation: UUID) async {
        guard let entry = entries[machineID], generation == entry.generation,
            !entry.interests.isEmpty
        else { return }
        entry.publicationTask = nil
        let snapshot = withObservationTracking {
            AgentMachineMetricsSnapshot(session: entry.session)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePublication(machineID: machineID, generation: generation)
            }
        }
        await emit(snapshot)
    }

    private func schedulePublication(machineID: UUID, generation: UUID) {
        guard let entry = entries[machineID], generation == entry.generation,
            !entry.interests.isEmpty, entry.publicationTask == nil
        else { return }
        entry.publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.observeAndPublish(machineID: machineID, generation: generation)
        }
    }

    private func emit(_ snapshot: AgentMachineMetricsSnapshot) async {
        let entry = entries[snapshot.machineID]
        if let failure = snapshot.state.failureMessage, failure != entry?.lastFailure, let runtime {
            let previous = activityTask
            let name = entry?.session.machine.name ?? snapshot.machineID.uuidString
            activityTask = Task {
                await previous?.value
                await runtime.record(
                    AgentEvent(
                        level: .warning, category: "machines", name: "metrics.failed",
                        message: "\(name): \(failure)"))
            }
        }
        entry?.lastFailure = snapshot.state.failureMessage
        await publish(snapshot)
        guard let runtime, let payload = try? AgentPayload.encode(snapshot) else { return }
        await runtime.publishBus(
            AgentBusMessage(
                channel: AgentMachineMetricInterest.metrics.channel(machineID: snapshot.machineID),
                body: payload), from: nil)
    }
}
