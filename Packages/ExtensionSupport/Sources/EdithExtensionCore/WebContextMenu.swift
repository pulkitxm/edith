import AppKit

public enum WebContextMenu {
    public static let newTabTitles: [String: String] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": "Open Link in New Tab",
        "WKMenuItemIdentifierOpenImageInNewWindow": "Open Image in New Tab",
        "WKMenuItemIdentifierOpenFrameInNewWindow": "Open Frame in New Tab",
        "WKMenuItemIdentifierOpenMediaInNewWindow": "Open Video in New Tab",
    ]

    public static func retitle(_ menu: NSMenu) {
        for item in menu.items {
            guard let identifier = item.identifier?.rawValue, let title = newTabTitles[identifier]
            else { continue }
            item.title = title
        }
    }
}
