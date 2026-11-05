import EdithHostCore
import Foundation

struct HostExtensionPlacement: Equatable, Identifiable {
    let symbolName: String
    let title: String
    let detail: String
    var id: String { title }
}

enum HostExtensionPlacements {
    static let hotkeyLimit = 3

    static func placements(
        for entry: HostExtension, hasSettings: Bool = false,
        route: (page: String, section: String?)? = nil, pageTitles: [String: String] = [:],
        sectionTitles: [String: String] = [:]
    ) -> [HostExtensionPlacement] {
        var result: [HostExtensionPlacement] = []
        if let route {
            if route.page == "appMaintenance" {
                let section = route.section.flatMap { sectionTitles[$0] } ?? entry.title
                result.append(
                    .init(
                        symbolName: "wrench.and.screwdriver", title: "Maintenance",
                        detail: "Open Maintenance in the sidebar and choose \(section)."))
            } else {
                let page = pageTitles[route.page] ?? entry.title
                result.append(
                    .init(
                        symbolName: "sidebar.left", title: "Sidebar",
                        detail: "Adds \(page) to the sidebar. Open it any time."))
            }
        } else if let page = entry.pages.min(by: { $0.order < $1.order }) {
            result.append(
                .init(
                    symbolName: "sidebar.left", title: "Sidebar",
                    detail: "Adds \(page.title) to the sidebar."))
        }
        if !entry.homeCards.isEmpty {
            result.append(
                .init(
                    symbolName: "house", title: "Home",
                    detail: entry.homeCards.count == 1
                        ? "Adds a card to Home that you can move or hide."
                        : "Adds \(entry.homeCards.count) cards to Home that you can move or hide."))
        }
        if !entry.notchCards.isEmpty || !entry.notchTabs.isEmpty {
            result.append(
                .init(
                    symbolName: "rectangle.topthird.inset.filled", title: "Notch",
                    detail: entry.notchTabs.isEmpty
                        ? "Adds a card to the notch panel."
                        : "Adds a tab to the notch panel."))
        }
        if !entry.hotkeys.isEmpty {
            let keys = entry.hotkeys.prefix(hotkeyLimit).map { "\($0.label) \($0.title)" }
            result.append(
                .init(
                    symbolName: "keyboard", title: "Hotkeys",
                    detail: keys.joined(separator: ", ") + ". Change them in Settings."))
        }
        if result.isEmpty {
            result.append(
                .init(
                    symbolName: "menubar.rectangle", title: "Background",
                    detail: hasSettings
                        ? "Runs quietly without a page of its own. Open this page any time to change its settings."
                        : "Runs quietly in the background without a page of its own."))
        }
        return result
    }

    static func hint(
        for entry: HostExtension, route: (page: String, section: String?)?,
        pageTitles: [String: String] = [:], sectionTitles: [String: String] = [:]
    ) -> String {
        if let route {
            if route.page == "appMaintenance" {
                return "Find it in the sidebar under Maintenance."
            }
            return "Find it in the sidebar as \(pageTitles[route.page] ?? entry.title)."
        }
        if let key = entry.hotkeys.first { return "Press \(key.label) to use it." }
        if !entry.notchCards.isEmpty || !entry.notchTabs.isEmpty {
            return "Find it in the notch panel."
        }
        if !entry.homeCards.isEmpty { return "Find its card on Home." }
        return "It runs in the background. Open its details any time."
    }
}
