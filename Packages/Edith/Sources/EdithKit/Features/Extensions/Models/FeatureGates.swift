import Foundation

public enum FeatureGates {
    public static func presenterActive(enabled: Bool, manual: Bool, autoActive: Bool) -> Bool {
        enabled && (manual || autoActive)
    }

    public static func presenterDetectorWanted(presenterEnabled: Bool, autoEnabled: Bool) -> Bool {
        presenterEnabled && autoEnabled
    }

    public static func preventSleepPersisted(keepAwakeOn: Bool, current: Bool) -> Bool {
        keepAwakeOn && current
    }

    public static func keystrokeHighlightMonitorWanted(enabled: Bool, active: Bool) -> Bool {
        enabled && active
    }
}

public enum ContextualPermissionGate {
    public static func shouldStartMonitor(
        isEnabled: Bool, wasEnabled: Bool, isGranted: Bool
    ) -> Bool {
        isEnabled && (isGranted || !wasEnabled)
    }
}

public enum ExtensionShortcut: String, CaseIterable, Hashable, Sendable {
    case bifrost
    case clipboard
    case emoji
    case micMute
    case focusDim
    case presenter
    case colorPicker
    case keystrokeHighlight
    case virtualCamera
}

public enum ExtensionShortcutVisibility {
    public static func visible(
        bifrost: Bool, clipboard: Bool, emoji: Bool, micMute: Bool, focusDim: Bool,
        presenter: Bool, colorPicker: Bool, keystrokeHighlight: Bool, virtualCamera: Bool = false
    ) -> [ExtensionShortcut] {
        let states: [(ExtensionShortcut, Bool)] = [
            (.bifrost, bifrost),
            (.clipboard, clipboard),
            (.emoji, emoji),
            (.micMute, micMute),
            (.focusDim, focusDim),
            (.presenter, presenter),
            (.colorPicker, colorPicker),
            (.keystrokeHighlight, keystrokeHighlight),
            (.virtualCamera, virtualCamera),
        ]
        return states.compactMap { shortcut, enabled in enabled ? shortcut : nil }
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
