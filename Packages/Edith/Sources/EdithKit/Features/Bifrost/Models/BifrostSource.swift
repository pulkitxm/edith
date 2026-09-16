import Foundation

public enum BifrostSource: String, CaseIterable, Codable, Hashable, Sendable {
    case quicklinks
    case snippets
    case shellCommands
    case appleShortcuts
    case windowActions
    case systemActions
    case runningApplications
    case openWindows

    public var title: String {
        switch self {
        case .quicklinks: "Quicklinks"
        case .snippets: "Snippets"
        case .shellCommands: "Shell commands"
        case .appleShortcuts: "Apple Shortcuts"
        case .windowActions: "Window management"
        case .systemActions: "System actions"
        case .runningApplications: "Running apps"
        case .openWindows: "Open windows"
        }
    }

    public var summary: String {
        switch self {
        case .quicklinks: "Your saved links, searches and deeplinks."
        case .snippets: "Reusable text, pasted into the app you were typing in."
        case .shellCommands: "Named commands run through your login shell."
        case .appleShortcuts: "Shortcuts you built in the Shortcuts app."
        case .windowActions: "Halves, quarters, thirds, nudges and display moves."
        case .systemActions: "Lock, sleep, appearance, trash and more."
        case .runningApplications: "Switch to or quit an app that is open now."
        case .openWindows: "Jump straight to an open window by title."
        }
    }

    public var symbolName: String {
        switch self {
        case .quicklinks: "link"
        case .snippets: "text.append"
        case .shellCommands: "terminal"
        case .appleShortcuts: "square.stack.3d.down.right"
        case .windowActions: "rectangle.split.2x1"
        case .systemActions: "switch.2"
        case .runningApplications: "bolt"
        case .openWindows: "macwindow.on.rectangle"
        }
    }

    public var defaultsKey: String {
        switch self {
        case .quicklinks: AppStorageKeys.Bifrost.sourceQuicklinks
        case .snippets: AppStorageKeys.Bifrost.sourceSnippets
        case .shellCommands: AppStorageKeys.Bifrost.sourceShellCommands
        case .appleShortcuts: AppStorageKeys.Bifrost.sourceAppleShortcuts
        case .windowActions: AppStorageKeys.Bifrost.sourceWindowActions
        case .systemActions: AppStorageKeys.Bifrost.sourceSystemActions
        case .runningApplications: AppStorageKeys.Bifrost.sourceRunningApplications
        case .openWindows: AppStorageKeys.Bifrost.sourceOpenWindows
        }
    }

    public var isOnByDefault: Bool {
        self != .openWindows
    }

    public var needsAccessibility: Bool {
        switch self {
        case .snippets, .windowActions, .openWindows: true
        default: false
        }
    }

    public func isEnabled(in defaults: UserDefaults = SharedDefaults.store) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? isOnByDefault
    }

    public static func enabled(
        in defaults: UserDefaults = SharedDefaults.store
    ) -> Set<BifrostSource> {
        Set(allCases.filter { $0.isEnabled(in: defaults) })
    }
}

public enum BifrostLibraryStore {
    public static func quicklinks(
        _ defaults: UserDefaults = SharedDefaults.store
    ) -> [BifrostQuicklink] {
        BifrostLibrary.load(
            BifrostQuicklink.self, key: AppStorageKeys.Bifrost.quicklinks, defaults: defaults)
    }

    public static func snippets(
        _ defaults: UserDefaults = SharedDefaults.store
    ) -> [BifrostSnippet] {
        BifrostLibrary.load(
            BifrostSnippet.self, key: AppStorageKeys.Bifrost.snippets, defaults: defaults)
    }

    public static func shellCommands(
        _ defaults: UserDefaults = SharedDefaults.store
    ) -> [BifrostShellCommand] {
        BifrostLibrary.load(
            BifrostShellCommand.self, key: AppStorageKeys.Bifrost.shellCommands,
            defaults: defaults)
    }

    public static func quicklink(
        id: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> BifrostQuicklink? {
        quicklinks(defaults).first { $0.id == id }
    }

    public static func snippet(
        id: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> BifrostSnippet? {
        snippets(defaults).first { $0.id == id }
    }

    public static func shellCommand(
        id: String, in defaults: UserDefaults = SharedDefaults.store
    ) -> BifrostShellCommand? {
        shellCommands(defaults).first { $0.id == id }
    }
}
