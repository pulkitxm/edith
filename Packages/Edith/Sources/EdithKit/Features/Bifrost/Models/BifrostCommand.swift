import EdithCore
import Foundation

public struct BifrostCommand: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let abilityID: String?
    public let notification: Notification.Name
    public let terms: [String]
    public let mode: BifrostMode?

    public init(
        id: String, title: String, subtitle: String, symbolName: String, abilityID: String?,
        notification: Notification.Name, terms: [String] = [], mode: BifrostMode? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
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
                symbolName: "doc.on.clipboard", abilityID: "clipboard",
                notification: IPC.Name.requestClipboardPanel,
                terms: ["paste", "copied", "history"], mode: .clipboard),
            BifrostCommand(
                id: "emoji.pick", title: "Emoji Picker",
                subtitle: "Type an emoji into the app in front of you",
                symbolName: "face.smiling", abilityID: "emoji",
                notification: IPC.Name.requestEmojiPanel,
                terms: ["emoji", "smiley", "symbol"]),
            BifrostCommand(
                id: "color.pick", title: "Color Picker",
                subtitle: "Sample a colour from anywhere on screen",
                symbolName: "eyedropper", abilityID: "colorPicker",
                notification: IPC.Name.requestColorPick,
                terms: ["colour", "hex", "eyedropper", "pick"]),
            BifrostCommand(
                id: "files.search", title: "Search Files",
                subtitle: "Find a file by name, or pick one you used lately",
                symbolName: "magnifyingglass", abilityID: nil,
                notification: IPC.Name.requestBifrostPanel,
                terms: ["file", "files", "finder", "document"], mode: .files),
            BifrostCommand(
                id: "panel.open", title: "Edith Panel",
                subtitle: "Open the menu bar panel", symbolName: "square.grid.2x2",
                abilityID: nil, notification: IPC.Name.openPanel,
                terms: ["edith", "menu bar", "panel"]),
            BifrostCommand(
                id: "bifrost.reindex", title: "Rebuild Application Index",
                subtitle: "Scan the application folders again",
                symbolName: "arrow.clockwise", abilityID: "bifrost",
                notification: IPC.Name.requestBifrostReindex,
                terms: ["reindex", "rescan", "refresh", "apps"]),
        ]
    }

    public static func command(id: String) -> BifrostCommand? {
        commands.first { $0.id == id }
    }

    public static func available(
        in defaults: UserDefaults = SharedDefaults.store
    ) -> [BifrostCommand] {
        commands.filter { command in
            guard let abilityID = command.abilityID else { return true }
            guard let entry = ExtensionRegistry.entry(abilityID) else { return false }
            return entry.isEnabled(in: defaults)
        }
    }
}
