import Foundation

public enum DockerContainerState: String, Equatable, Sendable {
    case created
    case running
    case paused
    case restarting
    case exited
    case dead
    case removing
    case unknown

    public init(raw: String) {
        self = DockerContainerState(rawValue: raw.lowercased()) ?? .unknown
    }

    public var isRunning: Bool { self == .running || self == .restarting }

    public var displayName: String {
        self == .unknown ? "Unknown" : rawValue.capitalized
    }
}

public enum DockerHealth: String, Equatable, Sendable {
    case none
    case starting
    case healthy
    case unhealthy
}

public struct DockerPortMapping: Equatable, Hashable, Sendable {
    public var hostIP: String?
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: String

    public init(hostIP: String?, hostPort: Int?, containerPort: Int, proto: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }

    public var displayName: String {
        guard let hostPort else { return "\(containerPort)/\(proto)" }
        return "\(hostPort) → \(containerPort)/\(proto)"
    }

    public var browserURL: URL? {
        guard let hostPort, proto == "tcp" else { return nil }
        return URL(string: "http://localhost:\(hostPort)")
    }
}

public struct DockerContainer: Identifiable, Equatable, Sendable {
    public var id: String
    public var names: [String]
    public var image: String
    public var command: String
    public var state: DockerContainerState
    public var status: String
    public var health: DockerHealth
    public var ports: [DockerPortMapping]
    public var composeProject: String?
    public var composeService: String?
    public var createdAt: String
    public var cpuPercent: Double?
    public var memUsedBytes: Int64?
    public var memLimitBytes: Int64?
    public var netRxBytes: Int64?
    public var netTxBytes: Int64?

    public init(
        id: String, names: [String], image: String, command: String,
        state: DockerContainerState, status: String, health: DockerHealth = .none,
        ports: [DockerPortMapping] = [], composeProject: String? = nil,
        composeService: String? = nil, createdAt: String = "", cpuPercent: Double? = nil,
        memUsedBytes: Int64? = nil, memLimitBytes: Int64? = nil, netRxBytes: Int64? = nil,
        netTxBytes: Int64? = nil
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.command = command
        self.state = state
        self.status = status
        self.health = health
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.createdAt = createdAt
        self.cpuPercent = cpuPercent
        self.memUsedBytes = memUsedBytes
        self.memLimitBytes = memLimitBytes
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
    }

    public var displayName: String { names.first ?? String(id.prefix(12)) }
    public var shortID: String { String(id.prefix(12)) }
}

public struct DockerImage: Identifiable, Equatable, Sendable {
    public var id: String
    public var repository: String
    public var tag: String
    public var createdSince: String
    public var sizeBytes: Int64
    public var dangling: Bool

    public init(
        id: String, repository: String, tag: String, createdSince: String, sizeBytes: Int64,
        dangling: Bool
    ) {
        self.id = id
        self.repository = repository
        self.tag = tag
        self.createdSince = createdSince
        self.sizeBytes = sizeBytes
        self.dangling = dangling
    }

    public var displayName: String {
        dangling ? "<none>:<none>" : "\(repository):\(tag)"
    }

    public var shortID: String {
        let trimmed = id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id
        return String(trimmed.prefix(12))
    }
}

public struct DockerVolume: Identifiable, Equatable, Sendable {
    public var name: String
    public var driver: String
    public var mountpoint: String
    public var sizeBytes: Int64?
    public var containerCount: Int?

    public var id: String { name }

    public init(
        name: String, driver: String, mountpoint: String, sizeBytes: Int64? = nil,
        containerCount: Int? = nil
    ) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.sizeBytes = sizeBytes
        self.containerCount = containerCount
    }

    public var inUse: Bool { (containerCount ?? 0) > 0 }
}

public struct DockerNetwork: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var driver: String
    public var scope: String

    public init(id: String, name: String, driver: String, scope: String) {
        self.id = id
        self.name = name
        self.driver = driver
        self.scope = scope
    }
}

public struct DockerDiskUsage: Equatable, Sendable {
    public var type: String
    public var totalCount: Int
    public var active: Int
    public var sizeBytes: Int64
    public var reclaimableBytes: Int64

    public init(
        type: String, totalCount: Int, active: Int, sizeBytes: Int64, reclaimableBytes: Int64
    ) {
        self.type = type
        self.totalCount = totalCount
        self.active = active
        self.sizeBytes = sizeBytes
        self.reclaimableBytes = reclaimableBytes
    }
}

public struct DockerAvailability: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case unknown
        case available(serverVersion: String, hasCompose: Bool)
        case missing
        case permissionDenied
        case daemonDown(message: String)
    }

    public var status: Status

    public init(status: Status) {
        self.status = status
    }

    public var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    public var isInstalled: Bool {
        switch status {
        case .missing: return false
        default: return true
        }
    }
}

public struct DockerLogLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var timestamp: String?
    public var text: String
    public var isStderr: Bool

    public init(id: Int, timestamp: String?, text: String, isStderr: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isStderr = isStderr
    }
}
