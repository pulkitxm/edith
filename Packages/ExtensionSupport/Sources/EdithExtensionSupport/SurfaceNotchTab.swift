import Foundation

public enum SurfaceNotchTab: String, CaseIterable, Equatable, Sendable {
    case home, agents, browser, files, clipboard, audio, camera

    public static func visible(
        layout: SurfaceLayout, activeIDs: Set<String>, browserEnabled: Bool = false
    ) -> [Self] {
        guard activeIDs.contains("notchShelf") else { return [] }
        return layout.tabOrder.compactMap(Self.init(rawValue:)).filter { tab in
            !layout.hiddenTabs.contains(tab.rawValue)
                && (tab != .browser || browserEnabled)
                && (tab == .home || !tab.providerIDs.isDisjoint(with: activeIDs))
        }
    }

    public var providerIDs: Set<String> {
        switch self {
        case .home: []
        case .agents: ["herdr"]
        case .browser: ["notchShelf"]
        case .files: ["notchShelf"]
        case .clipboard: ["clipboard"]
        case .audio: ["audioMixer"]
        case .camera: ["notchShelf"]
        }
    }

    public static func validSelection(_ selected: SurfaceNotchTab, visible: [SurfaceNotchTab])
        -> SurfaceNotchTab
    {
        visible.contains(selected) ? selected : .home
    }

    public var title: String {
        switch self {
        case .home: "Home"
        case .agents: "Agents"
        case .browser: "Browser"
        case .files: "Files"
        case .clipboard: "Clipboard"
        case .audio: "Audio"
        case .camera: "Camera"
        }
    }

    public var icon: String {
        switch self {
        case .home: "house.fill"
        case .agents: "terminal.fill"
        case .browser: "globe"
        case .files: "folder.fill"
        case .clipboard: "doc.on.clipboard"
        case .audio: "slider.horizontal.3"
        case .camera: "camera.fill"
        }
    }
}
