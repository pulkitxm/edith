import Foundation

public enum FeatureGates {
    public static func presenterActive(enabled: Bool, manual: Bool, autoActive: Bool) -> Bool {
        enabled && (manual || autoActive)
    }

    public static func presenterDetectorWanted(presenterEnabled: Bool, autoEnabled: Bool) -> Bool {
        presenterEnabled && autoEnabled
    }

    public static func preventSleepPersisted(systemOn: Bool, current: Bool) -> Bool {
        systemOn && current
    }
}

public struct AgentUsageSettingsState: Equatable, Sendable {
    public var enabled: Bool
    public var claudeEnabled: Bool
    public var codexEnabled: Bool
    public var menuBarEnabled: Bool
    public var alertsEnabled: Bool
    public var selectedProvider: LimitProvider

    public init(
        enabled: Bool, claudeEnabled: Bool, codexEnabled: Bool, menuBarEnabled: Bool,
        alertsEnabled: Bool, selectedProvider: LimitProvider
    ) {
        self.enabled = enabled
        self.claudeEnabled = claudeEnabled
        self.codexEnabled = codexEnabled
        self.menuBarEnabled = menuBarEnabled
        self.alertsEnabled = alertsEnabled
        self.selectedProvider = selectedProvider
    }

    public var hasProvider: Bool { claudeEnabled || codexEnabled }
}

public enum AgentUsageSettingsFlow {
    public static func providersChanged(_ state: AgentUsageSettingsState)
        -> AgentUsageSettingsState
    {
        guard !state.hasProvider else { return state }
        var next = state
        next.enabled = false
        next.menuBarEnabled = false
        next.alertsEnabled = false
        return next
    }

    public static func setEnabled(_ enabled: Bool, in state: AgentUsageSettingsState)
        -> AgentUsageSettingsState
    {
        var next = state
        next.enabled = enabled
        guard enabled, !next.hasProvider else { return next }
        switch next.selectedProvider {
        case .claude: next.claudeEnabled = true
        case .codex: next.codexEnabled = true
        }
        return next
    }
}
