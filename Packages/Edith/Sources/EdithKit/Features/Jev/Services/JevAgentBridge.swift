import Foundation

public enum JevAgentOperation {
    public static let status = "jev.status"
    public static let setKey = "jev.key.set"
    public static let decide = "jev.decide"
    public static let internalOperations = [status, setKey, decide]
}

public struct JevStatusQuery: Codable, Sendable, Equatable {
    public var probe: Bool

    public init(probe: Bool) {
        self.probe = probe
    }
}

public struct JevKeyUpdate: Codable, Sendable, Equatable {
    public var key: String?

    public init(key: String?) {
        self.key = key
    }
}

public struct JevCall: Codable, Sendable, Equatable {
    public var purpose: String
    public var request: JevRequest

    public init(purpose: String, request: JevRequest) {
        self.purpose = purpose
        self.request = request
    }
}

public struct JevReply: Codable, Sendable, Equatable {
    public var decision: JevDecision?
    public var error: JevError?

    public init(decision: JevDecision? = nil, error: JevError? = nil) {
        self.decision = decision
        self.error = error
    }

    public func unwrap() throws -> JevDecision {
        if let decision { return decision }
        throw error ?? JevError.malformedResponse
    }
}

public enum JevAvailability {
    public static func isConfigured(_ defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.bool(forKey: AppStorageKeys.Jev.configured)
    }

    public static func record(configured: Bool, in defaults: UserDefaults = SharedDefaults.store) {
        guard defaults.bool(forKey: AppStorageKeys.Jev.configured) != configured else { return }
        defaults.set(configured, forKey: AppStorageKeys.Jev.configured)
    }
}

public struct AgentJevDecider: JevDeciding {
    public static let timeout: TimeInterval = 12

    private let client: AgentClient

    public init(client: AgentClient = .shared) {
        self.client = client
    }

    public static func configured(
        defaults: UserDefaults = SharedDefaults.store, client: AgentClient = .shared
    ) -> AgentJevDecider? {
        JevAvailability.isConfigured(defaults) ? AgentJevDecider(client: client) : nil
    }

    public func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        let data = try await client.performInternalAsync(
            JevAgentOperation.decide,
            payload: AgentPayload.encode(JevCall(purpose: purpose, request: request)),
            timeout: Self.timeout)
        return try AgentPayload.decode(JevReply.self, from: data).unwrap()
    }

    public func status(probe: Bool) async throws -> JevStatus {
        let data = try await client.performInternalAsync(
            JevAgentOperation.status, payload: AgentPayload.encode(JevStatusQuery(probe: probe)),
            timeout: probe ? Self.timeout * 2 : AgentClient.replyTimeout)
        return try AgentPayload.decode(JevStatus.self, from: data)
    }

    public func setKey(_ key: String?) async throws -> JevStatus {
        let data = try await client.performInternalAsync(
            JevAgentOperation.setKey, payload: AgentPayload.encode(JevKeyUpdate(key: key)),
            timeout: Self.timeout * 2)
        return try AgentPayload.decode(JevStatus.self, from: data)
    }
}
