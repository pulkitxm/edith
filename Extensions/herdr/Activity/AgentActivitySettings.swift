import EdithExtensionSupport
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
    public static let defaultsKey = "agentActivityProviders"
    public var providers: [String: AgentActivityProviderSettings]
    public var quietMinutes: Int
    public var monitorTerminalAttention: Bool

    public init(
        providers: [String: AgentActivityProviderSettings] = [:], quietMinutes: Int = 10,
        monitorTerminalAttention: Bool = false
    ) {
        self.providers = providers
        self.quietMinutes = quietMinutes
        self.monitorTerminalAttention = monitorTerminalAttention
    }

    public func configuration(_ provider: AgentActivityProvider) -> AgentActivityProviderSettings {
        providers[provider.rawValue] ?? AgentActivityProviderSettings()
    }

    public var enabled: Bool { providers.values.contains { $0.observing } }

    public func normalized() -> Self {
        var result = self
        result.quietMinutes = min(120, max(2, quietMinutes))
        result.providers = providers.filter { AgentActivityProvider(rawValue: $0.key) != nil }
        for key in result.providers.keys {
            if result.providers[key]?.observing != true
                || AgentActivityProvider(rawValue: key)?.supportsPermissionApprovals != true
            {
                result.providers[key]?.approvals = false
            }
        }
        return result
    }

    public static func load(in defaults: UserDefaults = SharedDefaults.store) -> Self {
        guard let raw = defaults.string(forKey: defaultsKey),
            let data = raw.data(using: .utf8),
            let settings = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return settings.normalized()
    }

    public var encoded: String {
        String(data: (try? JSONEncoder().encode(normalized())) ?? Data(), encoding: .utf8) ?? ""
    }

    public func save() throws {
        SharedDefaults.store.set(encoded, forKey: defaultsKey)
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
    public static let ingest = "activity.ingest"
    public static let poll = "activity.poll"
    public static let decide = "activity.decide"
    public static let cancel = "activity.cancel"
    public static let internalOperations = [ingest, poll, decide, cancel]
}

public enum AgentActivityHookOutput {
    public static func data(provider: AgentActivityProvider, choice: AgentApprovalChoice?) throws
        -> Data
    {
        guard provider.supportsPermissionApprovals, let choice else { return Data("{}".utf8) }
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
