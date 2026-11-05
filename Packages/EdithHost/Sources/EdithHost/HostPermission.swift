import EdithExtensionSupport
import EdithExtensionUI
import Foundation

enum HostPermission: String, CaseIterable, Hashable, Sendable {
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

    var displayName: String {
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

    var reason: String {
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
        case .camera: "Asked when you first frame the Virtual Camera or open the notch camera."
        case .bluetooth: "Asked when Notch Shelf first checks for device connections."
        case .automation: "Asked when Notch Shelf first controls external playback."
        }
    }

    var grantedDefaultsKey: String? {
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

    var icon: EdithIcon {
        switch self {
        case .calendar: .calendar
        case .notifications: .permissionNotifications
        case .accessibility: .permissionAccessibility
        case .inputMonitoring: .permissionInputMonitoring
        case .fullDisk: .permissionFullDisk
        case .screenRecording: .permissionScreenRecording
        case .applicationAudio: .permissionApplicationAudio
        case .camera: .permissionCamera
        case .bluetooth: .permissionBluetooth
        case .automation: .permissionAutomation
        }
    }

    var needsRelaunch: Bool {
        [.inputMonitoring, .screenRecording, .fullDisk].contains(self)
    }

    var plainWords: String {
        switch self {
        case .calendar: "Lets Edith read your events so your schedule shows up in the app."
        case .notifications: "Lets Edith warn you before limits run out or when something finishes."
        case .accessibility:
            "Lets Edith press keys and read windows for you, for example to paste or move windows."
        case .inputMonitoring: "Lets Edith notice key presses for hotkeys and keystroke overlays."
        case .fullDisk: "Lets Edith read files macOS protects, such as usage data from other apps."
        case .screenRecording:
            "Lets Edith see what is on your screen to sample colors, blur numbers, or record."
        case .applicationAudio: "Lets Edith change the volume of individual apps."
        case .camera: "Lets Edith show and style your camera."
        case .bluetooth: "Lets Edith notice when headphones and other devices connect."
        case .automation: "Lets Edith control other apps such as your music player."
        }
    }

    var grantsOnFirstUse: Bool { [.applicationAudio, .bluetooth, .automation].contains(self) }

    var firstUseExplanation: String? {
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

extension HostPermission {
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

}
