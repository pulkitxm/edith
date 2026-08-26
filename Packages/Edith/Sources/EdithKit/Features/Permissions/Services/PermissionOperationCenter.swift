import AppKit
import EdithCore
import Foundation

public enum PermissionOperation: String, CaseIterable, Sendable {
    case status
    case request
    case refresh
    case settings

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .status:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "permissions.status"),
                summary: "Read Edith's mirrored permission state.",
                cli: ["permissions", "ls"], effect: .read)
        case .request:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "permissions.request"),
                summary: "Ask Edith to request a macOS permission.",
                cli: ["permissions", "request"], effect: .interactive)
        case .refresh:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "permissions.refresh"),
                summary: "Ask Edith to refresh its mirrored permission state.",
                cli: ["permissions", "refresh"], effect: .read)
        case .settings:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "permissions.settings"),
                summary: "Open the relevant macOS permission settings.",
                cli: ["permissions", "settings"], effect: .interactive)
        }
    }
}

public enum PermissionRelaunchRequirement: String, Equatable, Sendable {
    case none
    case edith
}

public enum PermissionRemediationAction: String, Equatable, Sendable {
    case none
    case request
    case firstUse
}

public struct PermissionRemediation: Equatable, Sendable {
    public let permission: ExtensionPermission
    public let granted: Bool
    public let action: PermissionRemediationAction
    public let settingsURL: URL?
    public let relaunch: PermissionRelaunchRequirement

    public init(
        permission: ExtensionPermission, granted: Bool, action: PermissionRemediationAction,
        settingsURL: URL?, relaunch: PermissionRelaunchRequirement
    ) {
        self.permission = permission
        self.granted = granted
        self.action = action
        self.settingsURL = settingsURL
        self.relaunch = relaunch
    }
}

public struct PermissionRequestResult: Equatable, Sendable {
    public let permission: ExtensionPermission
    public let requested: Bool
    public let granted: Bool
    public let settingsOpened: Bool
    public let relaunch: PermissionRelaunchRequirement

    public init(
        permission: ExtensionPermission, requested: Bool, granted: Bool,
        settingsOpened: Bool, relaunch: PermissionRelaunchRequirement
    ) {
        self.permission = permission
        self.requested = requested
        self.granted = granted
        self.settingsOpened = settingsOpened
        self.relaunch = relaunch
    }
}

public struct PermissionSettingsResult: Equatable, Sendable {
    public let permission: ExtensionPermission
    public let url: URL
    public let opened: Bool

    public init(permission: ExtensionPermission, url: URL, opened: Bool) {
        self.permission = permission
        self.url = url
        self.opened = opened
    }
}

public struct PermissionOnboardingDecision: Equatable, Sendable {
    public let items: [OnboardingPermission]
    public let hasOptionalPermissions: Bool

    public init(items: [OnboardingPermission], hasOptionalPermissions: Bool) {
        self.items = items
        self.hasOptionalPermissions = hasOptionalPermissions
    }
}

public enum PermissionOperationError: LocalizedError, Equatable, Sendable {
    case firstUse(ExtensionPermission)
    case noSettings(ExtensionPermission)
    case settingsFailed(ExtensionPermission)

    public var errorDescription: String? {
        switch self {
        case let .firstUse(permission):
            "\(permission.displayName) is granted on first use and cannot be requested"
        case let .noSettings(permission):
            "\(permission.displayName) has no settings page Edith can open"
        case let .settingsFailed(permission):
            "System Settings did not open for \(permission.displayName)"
        }
    }
}

public struct PermissionOperationEnvironment: @unchecked Sendable {
    public let defaults: UserDefaults
    public var requestPermission: (ExtensionPermission) -> Bool
    public var refreshStatus: () -> Void
    public var openSettings: (URL) -> Bool
    public var openPermissionOverview: () -> Bool
    public var recordPrompt: () -> Void

    public init(
        defaults: UserDefaults,
        requestPermission: @escaping (ExtensionPermission) -> Bool,
        refreshStatus: @escaping () -> Void, openSettings: @escaping (URL) -> Bool,
        openPermissionOverview: @escaping () -> Bool = { false },
        recordPrompt: @escaping () -> Void = {}
    ) {
        self.defaults = defaults
        self.requestPermission = requestPermission
        self.refreshStatus = refreshStatus
        self.openSettings = openSettings
        self.openPermissionOverview = openPermissionOverview
        self.recordPrompt = recordPrompt
    }

    public static var application: PermissionOperationEnvironment {
        PermissionOperationEnvironment(
            defaults: SharedDefaults.store,
            requestPermission: { permission in
                guard let request = permission.grantRequest else { return false }
                IPC.post(request)
                return false
            },
            refreshStatus: { IPC.post(IPC.Name.requestPermissionsRefresh) },
            openSettings: { NSWorkspace.shared.open($0) },
            openPermissionOverview: {
                MainActor.assumeIsolated {
                    MainApp.openSettings(tab: "permissions")
                    return true
                }
            })
    }

    public static func status(defaults: UserDefaults) -> PermissionOperationEnvironment {
        PermissionOperationEnvironment(
            defaults: defaults, requestPermission: { _ in false }, refreshStatus: {},
            openSettings: { _ in false })
    }
}

public struct PermissionOperationCenter: @unchecked Sendable {
    public var environment: PermissionOperationEnvironment

    public init(environment: PermissionOperationEnvironment) {
        self.environment = environment
    }

    public static var application: PermissionOperationCenter {
        PermissionOperationCenter(environment: .application)
    }

    public func status(filter: PermissionFilter = .all) -> [PermissionUsage] {
        PermissionCatalog.filter(
            PermissionsStatus.usages(defaults: environment.defaults), by: filter)
    }

    public func grantedPermissions() -> [ExtensionPermission: Bool] {
        PermissionsStatus.granted(defaults: environment.defaults)
    }

    @discardableResult
    public func refresh() -> [PermissionUsage] {
        environment.refreshStatus()
        return status()
    }

    public func remediation(for permission: ExtensionPermission) -> PermissionRemediation {
        let granted = PermissionsStatus.granted(defaults: environment.defaults)[permission] ?? false
        let action: PermissionRemediationAction
        if granted {
            action = .none
        } else if permission.grantRequest == nil {
            action = .firstUse
        } else {
            action = .request
        }
        return PermissionRemediation(
            permission: permission, granted: granted, action: action,
            settingsURL: permission.settingsURL, relaunch: permission.relaunchRequirement)
    }

    public func request(_ permission: ExtensionPermission) throws -> PermissionRequestResult {
        guard permission.grantRequest != nil else {
            throw PermissionOperationError.firstUse(permission)
        }
        environment.recordPrompt()
        let shouldOpenSettings = environment.requestPermission(permission)
        let settingsOpened =
            shouldOpenSettings
            && permission.settingsURL.map(environment.openSettings) == true
        return PermissionRequestResult(
            permission: permission, requested: true,
            granted: PermissionsStatus.granted(defaults: environment.defaults)[permission] ?? false,
            settingsOpened: settingsOpened, relaunch: permission.relaunchRequirement)
    }

    public func openSettings(for permission: ExtensionPermission) throws
        -> PermissionSettingsResult
    {
        guard let url = permission.settingsURL else {
            throw PermissionOperationError.noSettings(permission)
        }
        let opened = environment.openSettings(url)
        guard opened else { throw PermissionOperationError.settingsFailed(permission) }
        return PermissionSettingsResult(permission: permission, url: url, opened: true)
    }

    @discardableResult
    public func openPermissionOverview() -> Bool {
        environment.openPermissionOverview()
    }

    public func onboardingDecision(
        selectedIDs: Set<String>, entries: [ExtensionRegistryEntry] = ExtensionRegistry.entries
    ) -> PermissionOnboardingDecision {
        let granted = PermissionsStatus.granted(defaults: environment.defaults)
        return PermissionOnboardingDecision(
            items: OnboardingFlow.missingPermissions(
                selectedIDs: selectedIDs, entries: entries, granted: granted),
            hasOptionalPermissions: OnboardingFlow.hasOptionalPermissions(
                selectedIDs: selectedIDs, entries: entries))
    }
}

public extension ExtensionPermission {
    var settingsURL: URL? {
        let destination: String
        switch self {
        case .calendar:
            destination =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .notifications:
            destination = "x-apple.systempreferences:com.apple.preference.notifications"
        case .accessibility:
            destination =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            destination =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .fullDisk:
            destination = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .screenRecording:
            destination =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .applicationAudio:
            destination =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .camera:
            destination = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .bluetooth:
            destination =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .automation:
            return nil
        }
        return URL(string: destination)
    }

    var relaunchRequirement: PermissionRelaunchRequirement {
        switch self {
        case .accessibility, .inputMonitoring, .fullDisk, .screenRecording: .edith
        case .calendar, .notifications, .applicationAudio, .camera, .bluetooth, .automation: .none
        }
    }
}
