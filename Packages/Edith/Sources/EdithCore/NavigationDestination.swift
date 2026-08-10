import Foundation

public enum NavigationSection: String, CaseIterable, Sendable {
    case home = "Home"
    case application = "Application"
}

public enum NavigationDestination: String, CaseIterable, Identifiable, Sendable {
    case home
    case dashboard
    case music
    case calendar
    case system
    case machines
    case companion
    case extensions
    case settings
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .dashboard: "Agent Usage"
        case .music: "Music"
        case .calendar: "Calendar"
        case .system: "System"
        case .machines: "Machines"
        case .companion: "Companion"
        case .extensions: "Extensions"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    public var symbolName: String {
        switch self {
        case .home: "house.fill"
        case .dashboard: "chart.bar.fill"
        case .music: "music.note"
        case .calendar: "calendar"
        case .system: "cpu"
        case .machines: "server.rack"
        case .companion: "brain.head.profile"
        case .extensions: "puzzlepiece.extension"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }

    public var freedesktopIconName: String {
        switch self {
        case .home: "go-home-symbolic"
        case .dashboard: "org.gnome.Settings-usage-symbolic"
        case .music: "audio-x-generic-symbolic"
        case .calendar: "x-office-calendar-symbolic"
        case .system: "computer-symbolic"
        case .machines: "network-server-symbolic"
        case .companion: "chat-bubbles-text-symbolic"
        case .extensions: "application-x-addon-symbolic"
        case .settings: "preferences-system-symbolic"
        case .about: "help-about-symbolic"
        }
    }

    public var section: NavigationSection {
        switch self {
        case .home, .dashboard, .music, .calendar, .system, .machines, .companion: .home
        case .extensions, .settings, .about: .application
        }
    }

    public var extensionID: String? {
        switch self {
        case .dashboard: "usage"
        case .music: "music"
        case .calendar: "calendar"
        case .system: "system"
        case .machines: "machines"
        case .companion: "companion"
        case .home, .extensions, .settings, .about: nil
        }
    }

    public static func destinations(in section: NavigationSection) -> [NavigationDestination] {
        allCases.filter { $0.section == section }
    }

    public static func resolve(_ raw: String) -> NavigationDestination {
        NavigationDestination(rawValue: raw) ?? .home
    }
}
