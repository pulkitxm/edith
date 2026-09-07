import Foundation

public enum AgentMachineMetricInterest: String, CaseIterable, Codable, Sendable {
    case metrics
    case docker
    case speed

    public func channel(machineID: UUID) -> String {
        "machine.\(rawValue).\(machineID.uuidString)"
    }

    public static func parse(channel: String) -> (Self, UUID)? {
        let parts = channel.split(separator: ".")
        guard parts.count == 3, parts[0] == "machine",
            let interest = Self(rawValue: String(parts[1])),
            let machineID = UUID(uuidString: String(parts[2]))
        else { return nil }
        return (interest, machineID)
    }
}

public struct AgentMachineMetricsSnapshot: Codable, Equatable, Sendable {
    public let machineID: UUID
    public var state: MachineConnectionState
    public var platform: RemoteMachinePlatform?
    public var hello: MachineHello?
    public var sample: MachineSample?
    public var slow: MachineSlow?
    public var docker: DockerAvailability
    public var containersLoaded: Bool
    public var containers: [DockerContainer]
    public var images: [DockerImage]
    public var volumes: [DockerVolume]
    public var diskUsage: [DockerDiskUsage]
    public var networks: [DockerNetwork]
    public var facts: MachineSessionSummary
    public var mount: MachineMount?
    public var mountHealth: MountHealth?
    public var internetSpeed: InternetSpeedMeasurement?
    public var internetSpeedError: String?
    public var isTestingInternetSpeed: Bool

    @MainActor public init(session: MachineSession) {
        machineID = session.machine.id
        state = session.state
        platform = session.remotePlatform
        hello = session.hello
        sample = session.sample
        slow = session.slow
        docker = session.docker
        containersLoaded = session.containersLoaded
        containers = session.containers
        images = session.images
        volumes = session.volumes
        diskUsage = session.diskUsage
        networks = session.networks
        facts = session.facts
        mount = session.mount
        mountHealth = session.mountHealth
        internetSpeed = session.internetSpeed
        internetSpeedError = session.internetSpeedError
        isTestingInternetSpeed = session.isTestingInternetSpeed
    }
}

public struct AgentMachineMetricsRefresh: Codable, Sendable {
    public static let operation = "machine.metrics.refresh"
    public enum Action: String, Codable, Sendable {
        case docker
        case inventory
        case speed
        case reconnect
    }

    public let machineID: UUID
    public let action: Action

    public init(machineID: UUID, action: Action) {
        self.machineID = machineID
        self.action = action
    }
}

@MainActor
final class AgentMachineMetricObservation {
    private let client: AgentClient
    private let machineID: UUID
    private let receive: @MainActor (AgentMachineMetricsSnapshot) -> Void
    private let failed: @MainActor (String) -> Void
    private var subscriptions: [AgentMachineMetricInterest: AgentBusSubscription] = [:]
    private var interests: Set<AgentMachineMetricInterest> = []
    private var subscriptionTask: Task<Void, Never>?
    private var generation = 0
    private var deliveryID = UUID()

    init(
        client: AgentClient, machineID: UUID,
        receive: @escaping @MainActor (AgentMachineMetricsSnapshot) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) {
        self.client = client
        self.machineID = machineID
        self.receive = receive
        self.failed = failed
    }

    func update(_ desired: Set<AgentMachineMetricInterest>) {
        guard interests != desired else { return }
        interests = desired
        generation += 1
        subscriptionTask?.cancel()
        subscriptionTask = nil
        for interest in subscriptions.keys where !desired.contains(interest) {
            subscriptions.removeValue(forKey: interest)?.cancel()
        }
        if !desired.contains(.metrics) { deliveryID = UUID() }
        guard !desired.isEmpty else { return }
        let generation = generation
        let deliveryID = deliveryID
        subscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, generation == self.generation else { return }
                do {
                    for interest in AgentMachineMetricInterest.allCases
                    where desired.contains(interest) && subscriptions[interest] == nil {
                        let subscription = try await client.subscribeBusDataAsync(
                            channel: interest.channel(machineID: machineID)
                        ) { [weak self] data in
                            guard interest == .metrics else { return }
                            Task { @MainActor in
                                guard let self, deliveryID == self.deliveryID,
                                    self.interests.contains(.metrics),
                                    let snapshot = try? AgentPayload.decode(
                                        AgentMachineMetricsSnapshot.self, from: data),
                                    snapshot.machineID == self.machineID
                                else { return }
                                self.receive(snapshot)
                            }
                        }
                        guard !Task.isCancelled, generation == self.generation else {
                            subscription.cancel()
                            return
                        }
                        subscriptions[interest] = subscription
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, generation == self.generation else { return }
                    failed(error.localizedDescription)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func stop() { update([]) }

    deinit { subscriptionTask?.cancel() }
}
