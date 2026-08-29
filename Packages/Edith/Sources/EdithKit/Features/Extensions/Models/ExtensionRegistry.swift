import EdithCore
import Foundation

public typealias ExtensionGroup = EdithCore.ExtensionGroup
public typealias ExtensionMarketplaceCategory = EdithCore.ExtensionMarketplaceCategory
public typealias ExtensionMarketplaceFilter = EdithCore.ExtensionMarketplaceFilter
public typealias ExtensionRegistryEntry = EdithCore.ExtensionRegistryEntry
public typealias ExtensionRegistry = EdithCore.ExtensionRegistry
public typealias ExtensionLifecycleDescriptor = EdithCore.ExtensionLifecycleDescriptor
public typealias ExtensionLifecycleCheck = EdithCore.ExtensionLifecycleCheck
public typealias ExtensionLifecycleCheckStatus = EdithCore.ExtensionLifecycleCheckStatus
public typealias ExtensionLifecycleInstruction = EdithCore.ExtensionLifecycleInstruction
public typealias ExtensionLifecycleIssue = EdithCore.ExtensionLifecycleIssue
public typealias ExtensionLifecyclePhase = EdithCore.ExtensionLifecyclePhase
public typealias ExtensionLifecycleReport = EdithCore.ExtensionLifecycleReport
public typealias ExtensionRuntimePhase = EdithCore.ExtensionRuntimePhase
public typealias ExtensionLifecycleState = EdithCore.ExtensionLifecycleState
public typealias PlatformCapability = EdithCore.PlatformCapability
public typealias PlatformCapabilityState = EdithCore.PlatformCapabilityState
public typealias PlatformCapabilities = EdithCore.PlatformCapabilities

public enum ExtensionPermission: String, CaseIterable, Hashable, Sendable {
    case calendar
    case notifications
    case accessibility
    case inputMonitoring
    case fullDisk
    case screenRecording
    case applicationAudio
    case camera
    case bluetooth
    case automation

    public var displayName: String {
        switch self {
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .fullDisk: "Full Disk Access"
        case .screenRecording: "Screen Recording"
        case .applicationAudio: "Application Audio"
        case .camera: "Camera"
        case .bluetooth: "Bluetooth"
        case .automation: "Automation"
        }
    }

    public var reason: String {
        switch self {
        case .calendar: "Required to read and show your schedule in Calendar."
        case .notifications: "Asked when you enable usage limit, pacing, or reset alerts."
        case .accessibility:
            "Asked when you first use Clean keys, clipboard instant paste, or emoji insertion."
        case .inputMonitoring:
            "Asked when you first use Clean keys to block key presses during cleaning."
        case .fullDisk: "Asked when a feature needs local service credentials or usage data."
        case .screenRecording:
            "Required to detect shared content or sample colors from the screen."
        case .applicationAudio:
            "Asked when you first use the Notch Shelf per-app volume mixer."
        case .camera: "Asked when you first open the Notch Shelf camera preview."
        case .bluetooth: "Asked when Notch Shelf first checks for device connections."
        case .automation: "Asked when Notch Shelf first controls external playback."
        }
    }

    public var grantedDefaultsKey: String? {
        switch self {
        case .calendar: AppStorageKeys.Permissions.calendarGranted
        case .notifications: AppStorageKeys.Permissions.notificationsGranted
        case .accessibility: AppStorageKeys.Permissions.accessibilityGranted
        case .inputMonitoring: AppStorageKeys.Permissions.inputMonitoringGranted
        case .fullDisk: AppStorageKeys.Permissions.fullDiskGranted
        case .screenRecording: AppStorageKeys.Permissions.screenRecordingGranted
        case .camera: AppStorageKeys.Permissions.cameraGranted
        case .applicationAudio, .bluetooth, .automation: nil
        }
    }

    public var symbolName: String {
        switch self {
        case .calendar: "calendar"
        case .notifications: "bell.badge"
        case .accessibility: "figure.wave"
        case .inputMonitoring: "keyboard"
        case .fullDisk: "externaldrive"
        case .screenRecording: "rectangle.inset.filled.badge.record"
        case .applicationAudio: "speaker.wave.2"
        case .camera: "camera"
        case .bluetooth: "wave.3.right"
        case .automation: "gearshape.2"
        }
    }

    public var grantRequest: Notification.Name? {
        switch self {
        case .calendar: IPC.Name.grantCalendar
        case .notifications: IPC.Name.grantNotifications
        case .accessibility: IPC.Name.grantAccessibility
        case .inputMonitoring: IPC.Name.grantInputMonitoring
        case .fullDisk: IPC.Name.grantFullDisk
        case .screenRecording: IPC.Name.grantScreenRecording
        case .camera: IPC.Name.grantCamera
        case .applicationAudio, .bluetooth, .automation: nil
        }
    }

    public var firstUseExplanation: String? {
        switch self {
        case .bluetooth:
            "macOS will ask for Bluetooth access when connection alerts first run."
        case .automation:
            "macOS will ask for Automation access when Notch Shelf first controls playback."
        case .applicationAudio:
            "macOS will ask for application audio access when the mixer first changes an app."
        default: nil
        }
    }
}

public extension ExtensionRegistryEntry {
    var logoName: String? {
        id == "herdr" ? "herdr" : nil
    }

    var requiredPermissions: [ExtensionPermission] {
        switch id {
        case "calendar": [.calendar]
        case "focusDim", "presenter", "colorPicker": [.screenRecording]
        default: []
        }
    }

    var optionalPermissions: [ExtensionPermission] {
        switch id {
        case "automations", "focusProfiles": [.calendar, .notifications]
        case "usage", "machines": [.notifications]
        case "system": [.accessibility, .inputMonitoring]
        case "notchShelf": [.applicationAudio, .bluetooth, .camera, .automation]
        case "clipboard", "emoji": [.accessibility]
        default: []
        }
    }

    var requiredTools: [CLIToolSpec] {
        requiredToolIDs.compactMap(ToolProvisioning.spec(id:))
    }

    var optionalTools: [CLIToolSpec] {
        optionalToolIDs.compactMap(ToolProvisioning.spec(id:))
    }

    func isEnabled(in defaults: UserDefaults) -> Bool {
        if let stored = defaults.object(forKey: defaultsKey) as? Bool { return stored }
        guard let definition = ConfigCatalog.definition(for: defaultsKey),
            case let .bool(fallback) = definition.fallback
        else { return false }
        return fallback
    }
}

public enum ExtensionEnableDecision: Equatable, Sendable {
    case enableDirectly
    case showSheet(required: [ExtensionPermission], optional: [ExtensionPermission])
}

public enum ExtensionPermissionFlow {
    public static func decision(
        for entry: ExtensionRegistryEntry, granted: [ExtensionPermission: Bool],
        hasSeenPermissions _: Bool
    ) -> ExtensionEnableDecision {
        let missingRequired = entry.requiredPermissions.filter { granted[$0] != true }
        let missingOptional = entry.optionalPermissions.filter { granted[$0] != true }
        if !missingRequired.isEmpty {
            return .showSheet(required: missingRequired, optional: missingOptional)
        }
        return .enableDirectly
    }
}
