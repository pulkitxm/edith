import EdithCore
import Foundation

public typealias ExtensionGroup = EdithCore.ExtensionGroup
public typealias ExtensionMarketplaceCategory = EdithCore.ExtensionMarketplaceCategory
public typealias ExtensionMarketplaceFilter = EdithCore.ExtensionMarketplaceFilter
public typealias ExtensionRegistryEntry = EdithCore.ExtensionRegistryEntry
public typealias ExtensionRegistry = EdithCore.ExtensionRegistry

public enum ExtensionPermission: String, CaseIterable, Hashable, Sendable {
    case calendar
    case notifications
    case accessibility
    case inputMonitoring
    case fullDisk
    case screenRecording
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
            "Asked when you first use Clean keys or clipboard instant paste."
        case .inputMonitoring:
            "Asked when you first use Clean keys to block key presses during cleaning."
        case .fullDisk: "Asked when a feature needs local service credentials or usage data."
        case .screenRecording:
            "Required to detect shared content or sample colors from the screen."
        case .camera: "Asked when you first open the Notch Shelf camera preview."
        case .bluetooth: "Asked when Notch Shelf first checks for device connections."
        case .automation: "Asked when Notch Shelf first controls external playback."
        }
    }

    public var grantedDefaultsKey: String? {
        switch self {
        case .calendar: "permCalendarGranted"
        case .notifications: "permNotificationsGranted"
        case .accessibility: "permAccessibilityGranted"
        case .inputMonitoring: "permInputMonitoringGranted"
        case .fullDisk: "permFullDiskGranted"
        case .screenRecording: "permScreenRecordingGranted"
        case .camera: "permCameraGranted"
        case .bluetooth, .automation: nil
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
        case .bluetooth, .automation: nil
        }
    }

    public var firstUseExplanation: String? {
        switch self {
        case .bluetooth:
            "macOS will ask for Bluetooth access when connection alerts first run."
        case .automation:
            "macOS will ask for Automation access when Notch Shelf first controls playback."
        default: nil
        }
    }
}

public extension ExtensionRegistryEntry {
    var requiredPermissions: [ExtensionPermission] {
        switch id {
        case "calendar": [.calendar]
        case "focusDim", "presenter", "colorPicker": [.screenRecording]
        default: []
        }
    }

    var optionalPermissions: [ExtensionPermission] {
        switch id {
        case "usage", "machines": [.notifications]
        case "system": [.accessibility, .inputMonitoring]
        case "notchShelf": [.bluetooth, .camera, .automation]
        case "clipboard": [.accessibility]
        default: []
        }
    }

    var requiredTools: [CLIToolSpec] {
        requiredToolIDs.compactMap(ToolProvisioning.spec(id:))
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
