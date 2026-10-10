import Foundation

public enum HostCoreJobTrigger: String, Codable, CaseIterable, Sendable {
    case timer
    case fileSystem
    case subscription
    case queue

    public var title: String {
        switch self {
        case .timer: "Timer"
        case .fileSystem: "File changes"
        case .subscription: "Subscription"
        case .queue: "Queue"
        }
    }
}

public enum HostCoreJobPower: String, Codable, CaseIterable, Sendable {
    case any
    case pauseOnLock
    case pauseOnBattery

    public var title: String {
        switch self {
        case .any: "Always"
        case .pauseOnLock: "Paused while locked"
        case .pauseOnBattery: "Paused on battery"
        }
    }
}

public struct HostCoreJobCadence: Codable, Equatable, Sendable {
    public let ambient: TimeInterval?
    public let live: TimeInterval?

    public init(ambient: TimeInterval?, live: TimeInterval?) {
        self.ambient = ambient
        self.live = live
    }

    public static let onDemand = HostCoreJobCadence(ambient: nil, live: nil)

    public static func every(
        ambient: TimeInterval? = nil, live: TimeInterval? = nil
    ) -> HostCoreJobCadence {
        HostCoreJobCadence(ambient: ambient, live: live)
    }
}

public struct HostCoreJobDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let trigger: HostCoreJobTrigger
    public let topic: String?
    public let cadence: HostCoreJobCadence
    public let power: HostCoreJobPower
    public let abilityID: String?

    public init(
        id: String, title: String, trigger: HostCoreJobTrigger, topic: String? = nil,
        cadence: HostCoreJobCadence = .onDemand, power: HostCoreJobPower = .any,
        abilityID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.topic = topic
        self.cadence = cadence
        self.power = power
        self.abilityID = abilityID
    }
}

public enum HostCoreJobPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case running
    case paused
    case disabled
    case failed

    public var title: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .paused: "Paused"
        case .disabled: "Off"
        case .failed: "Failed"
        }
    }
}

public struct HostCoreJobSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let descriptor: HostCoreJobDescriptor
    public let phase: HostCoreJobPhase
    public let subscribers: Int
    public let lastRun: Date?
    public let lastDuration: TimeInterval?
    public let lastError: String?
    public let runCount: Int

    public var id: String { descriptor.id }

    public init(
        descriptor: HostCoreJobDescriptor, phase: HostCoreJobPhase, subscribers: Int,
        lastRun: Date?, lastDuration: TimeInterval?, lastError: String?, runCount: Int
    ) {
        self.descriptor = descriptor
        self.phase = phase
        self.subscribers = subscribers
        self.lastRun = lastRun
        self.lastDuration = lastDuration
        self.lastError = lastError
        self.runCount = runCount
    }

    public var effectiveInterval: TimeInterval? {
        subscribers > 0
            ? descriptor.cadence.live ?? descriptor.cadence.ambient
            : descriptor.cadence.ambient
    }
}

public struct HostCoreAgentEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, CaseIterable, Sendable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: String
    public let name: String
    public let message: String
    public let duration: TimeInterval?
    public let taskID: UUID?

    public init(
        id: UUID = UUID(), date: Date = Date(), level: Level = .info,
        category: String, name: String, message: String, duration: TimeInterval? = nil,
        taskID: UUID? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = String(category.prefix(80))
        self.name = String(name.prefix(160))
        self.message = String(message.prefix(2_000))
        self.duration = duration
        self.taskID = taskID
    }
}

public struct HostCoreAgentSnapshot: Codable, Sendable {
    public let build: String
    public let storePath: String
    public let schemaVersion: Int
    public let protocolVersion: Int
    public let jobs: [HostCoreJobSnapshot]
    public let events: [HostCoreAgentEvent]
}

public struct HostCoreAgentStatus: Codable, Sendable {
    public let state: String
    public let build: String
    public let pid: Int32
    public let uptimeSeconds: Int
    public let residentBytes: UInt64
    public let cpuPercent: Double
    public internal(set) var subscribers: Int
    public let store: String
    public let schemaVersion: Int
    public let protocolVersion: Int

    public init(snapshot: HostCoreSnapshot, cpuPercent: Double, subscribers: Int = 0) throws {
        guard let agent = snapshot.agent, snapshot.pid > 0,
            cpuPercent.isFinite, cpuPercent >= 0, subscribers >= 0
        else { throw HostCLIError.unavailable }
        state = "enabled"
        build = agent.build
        pid = snapshot.pid
        uptimeSeconds = max(0, Int(snapshot.collectedAt.timeIntervalSince(snapshot.startedAt)))
        residentBytes = snapshot.residentBytes
        self.cpuPercent = cpuPercent
        self.subscribers = subscribers
        store = agent.storePath
        schemaVersion = agent.schemaVersion
        protocolVersion = agent.protocolVersion
    }
}
