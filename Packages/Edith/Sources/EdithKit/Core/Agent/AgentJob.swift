import Foundation

public enum AgentJobTrigger: String, Codable, CaseIterable, Sendable {
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

public enum AgentPowerPolicy: String, Codable, CaseIterable, Sendable {
    case any
    case pauseOnLock
    case pauseOnSleep
    case pauseOnBattery

    public var title: String {
        switch self {
        case .any: "Always"
        case .pauseOnLock: "Paused while locked"
        case .pauseOnSleep: "Paused while asleep"
        case .pauseOnBattery: "Paused on battery"
        }
    }
}

public struct AgentCadence: Codable, Equatable, Sendable {
    public let ambient: TimeInterval?
    public let live: TimeInterval?

    public init(ambient: TimeInterval?, live: TimeInterval?) {
        self.ambient = ambient
        self.live = live
    }

    public static let onDemand = AgentCadence(ambient: nil, live: nil)

    public static func every(
        ambient: TimeInterval? = nil, live: TimeInterval? = nil
    ) -> AgentCadence {
        AgentCadence(ambient: ambient, live: live)
    }
}

public struct AgentJobDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let trigger: AgentJobTrigger
    public let topic: AgentTopic?
    public let cadence: AgentCadence
    public let power: AgentPowerPolicy
    public let abilityID: String?

    public init(
        id: String, title: String, trigger: AgentJobTrigger, topic: AgentTopic? = nil,
        cadence: AgentCadence = .onDemand, power: AgentPowerPolicy = .any,
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

public enum AgentJobPhase: String, Codable, CaseIterable, Sendable {
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

public struct AgentJobSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let descriptor: AgentJobDescriptor
    public let phase: AgentJobPhase
    public let subscribers: Int
    public let lastRun: Date?
    public let lastDuration: TimeInterval?
    public let lastError: String?
    public let runCount: Int

    public var id: String { descriptor.id }

    public init(
        descriptor: AgentJobDescriptor, phase: AgentJobPhase, subscribers: Int,
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

public enum AgentCadenceMath {
    public static func interval(
        for cadence: AgentCadence, subscribers: Int, pauseAmbient: Bool
    ) -> TimeInterval? {
        if subscribers > 0, let live = cadence.live { return live }
        if pauseAmbient { return nil }
        return cadence.ambient
    }

    public static func tolerance(for interval: TimeInterval) -> TimeInterval {
        max(1, interval * 0.1)
    }
}
