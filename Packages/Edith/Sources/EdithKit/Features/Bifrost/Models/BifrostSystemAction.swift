import Foundation

public enum BifrostSystemAction: String, CaseIterable, Codable, Hashable, Sendable {
    case lockScreen
    case sleepMac
    case sleepDisplays
    case startScreenSaver
    case logOut
    case restartMac
    case shutDownMac
    case emptyTrash
    case toggleAppearance
    case toggleHiddenFiles
    case quitAllApps
    case ejectAllDisks

    public var title: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleepMac: "Sleep"
        case .sleepDisplays: "Sleep Displays"
        case .startScreenSaver: "Start Screen Saver"
        case .logOut: "Log Out"
        case .restartMac: "Restart"
        case .shutDownMac: "Shut Down"
        case .emptyTrash: "Empty Trash"
        case .toggleAppearance: "Toggle Dark Mode"
        case .toggleHiddenFiles: "Toggle Hidden Files"
        case .quitAllApps: "Quit All Apps"
        case .ejectAllDisks: "Eject All Disks"
        }
    }

    public var subtitle: String {
        switch self {
        case .lockScreen: "Lock this Mac straight away."
        case .sleepMac: "Put the Mac to sleep."
        case .sleepDisplays: "Turn the displays off without sleeping."
        case .startScreenSaver: "Start the screen saver."
        case .logOut: "Log the current user out."
        case .restartMac: "Restart this Mac."
        case .shutDownMac: "Shut this Mac down."
        case .emptyTrash: "Empty the Trash."
        case .toggleAppearance: "Switch between light and dark appearance."
        case .toggleHiddenFiles: "Show or hide dotfiles in Finder."
        case .quitAllApps: "Quit every app except Finder and Edith."
        case .ejectAllDisks: "Eject every removable volume."
        }
    }

    public var symbolName: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .sleepMac: "moon.fill"
        case .sleepDisplays: "display"
        case .startScreenSaver: "photo.on.rectangle"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .restartMac: "arrow.clockwise"
        case .shutDownMac: "power"
        case .emptyTrash: "trash"
        case .toggleAppearance: "circle.lefthalf.filled"
        case .toggleHiddenFiles: "eye"
        case .quitAllApps: "xmark.app"
        case .ejectAllDisks: "eject"
        }
    }

    public var keywords: [String] {
        switch self {
        case .lockScreen: ["lock", "secure", "screen"]
        case .sleepMac: ["sleep", "suspend"]
        case .sleepDisplays: ["display", "monitor", "off"]
        case .startScreenSaver: ["saver", "idle"]
        case .logOut: ["logout", "sign out"]
        case .restartMac: ["reboot", "restart"]
        case .shutDownMac: ["shutdown", "power off"]
        case .emptyTrash: ["trash", "bin", "delete"]
        case .toggleAppearance: ["dark", "light", "theme", "appearance"]
        case .toggleHiddenFiles: ["hidden", "dotfiles", "finder"]
        case .quitAllApps: ["quit", "close all"]
        case .ejectAllDisks: ["eject", "unmount", "volume"]
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .logOut, .restartMac, .shutDownMac, .emptyTrash, .quitAllApps: true
        default: false
        }
    }

    public var needsConfirmation: Bool {
        isDestructive
    }
}
