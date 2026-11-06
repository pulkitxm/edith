import EdithIcons
import EdithHostCore
import Foundation

struct HostExtensionPlacement: Equatable, Identifiable {
    let icon: EdithIcon
    let title: String
    let detail: String
    var id: String { title }
}

enum HostExtensionPlacements {
    static let hotkeyLimit = 3

    static func group(of entry: HostExtension) -> String {
        HostMarketplaceCatalog.suite(for: entry)?.title ?? entry.category
    }

    static func placements(for entry: HostExtension, hasSettings: Bool = false)
        -> [HostExtensionPlacement]
    {
        var result: [HostExtensionPlacement] = []
        if entry.page != nil {
            result.append(
                .init(
                    icon: .sidebarLeft, title: "Sidebar",
                    detail: "Adds \(entry.title) to the sidebar under \(group(of: entry))."))
        }
        if !entry.homeCards.isEmpty {
            result.append(
                .init(
                    icon: .home, title: "Home",
                    detail: entry.homeCards.count == 1
                        ? "Adds a card to Home that you can move or hide."
                        : "Adds \(entry.homeCards.count) cards to Home that you can move or hide."))
        }
        if !entry.notchCards.isEmpty || !entry.notchTabs.isEmpty {
            result.append(
                .init(
                    icon: .layoutTop, title: "Notch",
                    detail: entry.notchTabs.isEmpty
                        ? "Adds a card to the notch panel."
                        : "Adds a tab to the notch panel."))
        }
        if !entry.hotkeys.isEmpty {
            let keys = entry.hotkeys.prefix(hotkeyLimit).map { "\($0.label) \($0.title)" }
            result.append(
                .init(
                    icon: .keyboard, title: "Hotkeys",
                    detail: keys.joined(separator: ", ") + ". Change them in Settings."))
        }
        if result.isEmpty {
            result.append(
                .init(
                    icon: .menuBar, title: "Background",
                    detail: hasSettings
                        ? "Runs quietly without a page of its own. Open this page any time to change its settings."
                        : "Runs quietly in the background without a page of its own."))
        }
        return result
    }

    static func hint(for entry: HostExtension) -> String {
        if entry.page != nil {
            return "Find \(entry.title) in the sidebar under \(group(of: entry))."
        }
        if let key = entry.hotkeys.first { return "Press \(key.label) to use it." }
        if !entry.notchCards.isEmpty || !entry.notchTabs.isEmpty {
            return "Find it in the notch panel."
        }
        if !entry.homeCards.isEmpty { return "Find its card on Home." }
        return "It runs in the background. Open its details any time."
    }
}
