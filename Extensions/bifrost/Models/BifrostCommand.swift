import EdithExtensionSupport
import EdithIcons
import Foundation

public struct BifrostCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: EdithIcon
    public let abilityID: String?
    public let notification: Notification.Name
    public let terms: [String]
    public let mode: BifrostMode?

    public init(
        id: String, title: String, subtitle: String, icon: EdithIcon, abilityID: String?,
        notification: Notification.Name, terms: [String] = [], mode: BifrostMode? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.abilityID = abilityID
        self.notification = notification
        self.terms = terms
        self.mode = mode
    }

    public var searchText: String {
        ([title] + terms).joined(separator: " ")
    }
}

public enum BifrostCommandCatalog {
    public static var commands: [BifrostCommand] {
        [
            BifrostCommand(
                id: "clipboard.open", title: "Clipboard History",
                subtitle: "Paste something you copied earlier",
                icon: .clipboard, abilityID: "clipboard",
                notification: BifrostIPC.Name.requestClipboardPanel,
                terms: ["paste", "copied", "history"], mode: .clipboard),
            BifrostCommand(
                id: "emoji.pick", title: "Emoji Picker",
                subtitle: "Type an emoji into the app in front of you",
                icon: .emoji, abilityID: "emoji",
                notification: BifrostIPC.Name.requestEmojiPanel,
                terms: ["emoji", "smiley", "symbol"]),
            BifrostCommand(
                id: "color.pick", title: "Color Picker",
                subtitle: "Sample a colour from anywhere on screen",
                icon: .eyedropper, abilityID: "colorPicker",
                notification: BifrostIPC.Name.requestColorPick,
                terms: ["colour", "hex", "eyedropper", "pick"]),
            BifrostCommand(
                id: "files.search", title: "Search Files",
                subtitle: "Find a file by name, or pick one you used lately",
                icon: .search, abilityID: nil,
                notification: BifrostIPC.Name.requestBifrostPanel,
                terms: ["file", "files", "finder", "document"], mode: .files),
            BifrostCommand(
                id: "panel.open", title: "Edith Panel",
                subtitle: "Open the menu bar panel", icon: .grid,
                abilityID: nil, notification: BifrostIPC.Name.openPanel,
                terms: ["edith", "menu bar", "panel"]),
            BifrostCommand(
                id: "bifrost.reindex", title: "Rebuild Application Index",
                subtitle: "Scan the application folders again",
                icon: .refresh, abilityID: "bifrost",
                notification: BifrostIPC.Name.requestBifrostReindex,
                terms: ["reindex", "rescan", "refresh", "apps"]),
        ]
    }

    public static func command(id: String) -> BifrostCommand? {
        commands.first { $0.id == id }
    }

    public static func available(
        in defaults: UserDefaults = SharedDefaults.store,
        activeIDs: Set<String> = BifrostPeers.activeIDs
    ) -> [BifrostCommand] {
        commands.filter { command in
            guard let abilityID = command.abilityID else { return true }
            return activeIDs.contains(abilityID)
        }
    }
}
