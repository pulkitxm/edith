import Foundation

public struct AgentActivityProviderSettings: Codable, Equatable, Sendable {
    public var observing: Bool
    public var approvals: Bool
    public init(observing: Bool = false, approvals: Bool = false) {
        self.observing = observing
        self.approvals = approvals
    }
}

public struct AgentActivitySettings: Codable, Equatable, Sendable {
    public var providers: [String: AgentActivityProviderSettings]
    public var quietMinutes: Int

    public init(providers: [String: AgentActivityProviderSettings] = [:], quietMinutes: Int = 10) {
        self.providers = providers
        self.quietMinutes = quietMinutes
    }

    public func configuration(_ provider: AgentActivityProvider) -> AgentActivityProviderSettings {
        providers[provider.rawValue] ?? AgentActivityProviderSettings()
    }

    public var enabled: Bool { providers.values.contains { $0.observing } }

    public func normalized() -> Self {
        var result = self
        result.quietMinutes = min(120, max(2, quietMinutes))
        result.providers = providers.filter { AgentActivityProvider(rawValue: $0.key) != nil }
        for key in result.providers.keys where result.providers[key]?.observing != true {
            result.providers[key]?.approvals = false
        }
        return result
    }

    public static func load(in defaults: UserDefaults = SharedDefaults.store) -> Self {
        guard let raw = defaults.string(forKey: AppStorageKeys.Surfaces.agentActivity),
            let data = raw.data(using: .utf8),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return settings.normalized()
    }

    public var encoded: String {
        String(data: (try? JSONEncoder().encode(normalized())) ?? Data(), encoding: .utf8) ?? ""
    }

    public func save() throws {
        try ConfigurationExecutor.application.set(
            .string(encoded), forKey: AppStorageKeys.Surfaces.agentActivity)
    }
}

public struct AgentActivityReceipt: Codable, Equatable, Sendable {
    public var token: AgentApprovalToken?
    public var expiresAt: Date?
    public init(request: AgentApprovalRequest? = nil) {
        token = request.map(AgentApprovalToken.init)
        expiresAt = request?.expiresAt
    }
}

public enum AgentActivityOperation {
    public static let ingest = "agentActivity.ingest"
    public static let poll = "agentActivity.poll"
    public static let decide = "agentActivity.decide"
    public static let cancel = "agentActivity.cancel"
    public static let internalOperations = [ingest, poll, decide, cancel]
}

public enum AgentActivityHookOutput {
    public static func data(provider: AgentActivityProvider, choice: AgentApprovalChoice?) throws
        -> Data
    {
        guard let choice else { return Data("{}".utf8) }
        if provider == .opencode {
            return try JSONSerialization.data(withJSONObject: ["choice": choice.rawValue])
        }
        var decision: [String: Any] = ["behavior": choice == .allowOnce ? "allow" : "deny"]
        if choice == .deny { decision["message"] = "Denied in Edith." }
        return try JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest", "decision": decision,
            ]
        ])
    }
}
