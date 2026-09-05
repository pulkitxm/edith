import Foundation

public enum AgentService {
    public static let machServiceName = "com.pulkit.edith.agent"
    public static let plistName = "com.pulkit.edith.agent.plist"
    public static let label = "com.pulkit.edith.agent"
    public static let executableName = "edithd"
    public static let stateKey = "agentRegistrationState"
    public static let protocolVersion = 1

    public static var bundledPlistURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }
}

public enum AgentSettingsKeys {
    public static let pauseAmbientOnBattery = "agentPauseAmbientOnBattery"
    public static let notifyWhenBlocked = "agentNotifyWhenBlocked"
}

public enum AgentRegistrationState: String, CaseIterable, Codable, Sendable {
    case notRegistered
    case enabled
    case awaitingApproval
    case notFound

    public var title: String {
        switch self {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .awaitingApproval: "Waiting for approval"
        case .notFound: "Not found"
        }
    }

    public var needsAttention: Bool {
        self != .enabled
    }

    public static var current: AgentRegistrationState {
        stored(in: SharedDefaults.store)
    }

    public static func stored(in defaults: UserDefaults) -> AgentRegistrationState {
        guard let raw = defaults.string(forKey: AgentService.stateKey),
            let state = AgentRegistrationState(rawValue: raw)
        else { return .notRegistered }
        return state
    }
}

public enum AgentTopic: String, CaseIterable, Codable, Sendable {
    case usage
    case limits
    case sessions
    case machines
    case machineMetrics
    case updates
    case cleaner
    case downloads
    case attention
    case companion
    case siteAudit
    case backup
    case jobs
    case events

    public var title: String {
        switch self {
        case .usage: "Usage"
        case .limits: "Limits"
        case .sessions: "Sessions"
        case .machines: "Machines"
        case .machineMetrics: "Machine metrics"
        case .updates: "Updates"
        case .cleaner: "Cleaner"
        case .downloads: "Downloads"
        case .attention: "Attention"
        case .companion: "Memory"
        case .siteAudit: "Site Audit"
        case .backup: "Backup"
        case .jobs: "Jobs"
        case .events: "Events"
        }
    }
}

public struct AgentHandshake: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let build: String
    public let startedAt: Date

    public init(protocolVersion: Int, build: String, startedAt: Date) {
        self.protocolVersion = protocolVersion
        self.build = build
        self.startedAt = startedAt
    }
}

public enum AgentProtocolCompatibility {
    public static func verdict(peer: Int, agent: Int) -> AgentCompatibilityVerdict {
        if peer == agent { return .compatible }
        return peer < agent ? .peerIsOlder : .agentIsOlder
    }
}

public enum AgentCompatibilityVerdict: Equatable, Sendable {
    case compatible
    case peerIsOlder
    case agentIsOlder

    public var hint: String? {
        switch self {
        case .compatible: nil
        case .peerIsOlder:
            "This copy of Edith is older than the running background agent. Relaunch Edith."
        case .agentIsOlder:
            "The background agent is older than this copy of Edith. "
                + "Restart it from Settings, Background agent."
        }
    }
}

public struct AgentError: LocalizedError, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unavailable
        case incompatible
        case refused
        case failed
        case unknownTopic
        case unknownOperation
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }

    public static let unavailable = AgentError(
        .unavailable, "The Edith background agent is not running.")
}
