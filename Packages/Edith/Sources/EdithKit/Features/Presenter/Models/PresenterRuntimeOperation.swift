import EdithCore
import Foundation

public enum PresenterRuntimeOperation: String, CaseIterable, Sendable {
    case status
    case start
    case stop

    public var descriptor: UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "presenter.runtime.\(rawValue)"),
            summary: summary, cli: ["presenter", rawValue],
            effect: self == .status ? .read : .write)
    }

    private var summary: String {
        switch self {
        case .status: return "Show presenter runtime state."
        case .start: return "Start manual presenter mode."
        case .stop: return "Stop manual presenter mode."
        }
    }
}

public struct PresenterRuntimeSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let manual: Bool
    public let autoActive: Bool
    public let autoReason: String?
    public let active: Bool

    public init(
        enabled: Bool, manual: Bool, autoActive: Bool, autoReason: String?, active: Bool
    ) {
        self.enabled = enabled
        self.manual = manual
        self.autoActive = autoActive
        self.autoReason = autoReason
        self.active = active
    }
}

public enum PresenterRuntimeOperationExecution {
    public static func status(defaults: UserDefaults = SharedDefaults.store)
        -> PresenterRuntimeSnapshot
    {
        let enabled = defaults.object(forKey: AppStorageKeys.Presenter.enabled) as? Bool ?? false
        let manual = enabled && defaults.bool(forKey: AppStorageKeys.Presenter.mode)
        let autoActive = enabled && defaults.bool(forKey: AppStorageKeys.Presenter.autoActive)
        return PresenterRuntimeSnapshot(
            enabled: enabled, manual: manual, autoActive: autoActive,
            autoReason: enabled
                ? defaults.string(forKey: AppStorageKeys.Presenter.autoReason) : nil,
            active: FeatureGates.presenterActive(
                enabled: enabled, manual: manual, autoActive: autoActive))
    }

    @discardableResult
    public static func perform(
        _ operation: PresenterRuntimeOperation, defaults: UserDefaults = SharedDefaults.store,
        post: (Notification.Name) -> Void = { IPC.post($0) }
    ) -> PresenterRuntimeSnapshot {
        guard operation != .status else { return status(defaults: defaults) }
        guard status(defaults: defaults).enabled else { return status(defaults: defaults) }
        defaults.set(operation == .start, forKey: AppStorageKeys.Presenter.mode)
        if operation == .stop { post(IPC.Name.presenterPauseAuto) }
        post(IPC.Name.settingsChanged)
        return status(defaults: defaults)
    }
}
