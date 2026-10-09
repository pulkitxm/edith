import Foundation

public enum SurfaceNotchTab: String, CaseIterable, Equatable, Sendable {
    case home, agents, browser, files, clipboard, audio, camera

    public static func visible(
        clipboardEnabled: Bool, audioMixerEnabled: Bool, applicationAudioSupported: Bool,
        browserEnabled: Bool = false, agentsEnabled: Bool = false
    ) -> [SurfaceNotchTab] {
        var tabs: [SurfaceNotchTab] = [.home]
        if agentsEnabled { tabs.append(.agents) }
        if browserEnabled { tabs.append(.browser) }
        tabs.append(.files)
        if clipboardEnabled { tabs.append(.clipboard) }
        if audioMixerEnabled, applicationAudioSupported { tabs.append(.audio) }
        tabs.append(.camera)
        return tabs
    }

    public static var currentVisible: [SurfaceNotchTab] {
        let available = visible(
            clipboardEnabled: SharedDefaults.store.bool(forKey: AppStorageKeys.Clipboard.enabled),
            audioMixerEnabled: SharedDefaults.store.bool(
                forKey: AppStorageKeys.Notch.audioMixerEnabled),
            applicationAudioSupported: PlatformCapabilities.macOS.state(for: .applicationAudio)
                .isSupported,
            browserEnabled: SharedDefaults.store.bool(forKey: AppStorageKeys.Notch.browserEnabled),
            agentsEnabled: true)
        let layout = SurfaceLayout.decode(
            SharedDefaults.store.string(forKey: SurfaceTarget.notch.key), target: .notch)
        return layout.tabOrder.compactMap(Self.init(rawValue:)).filter {
            available.contains($0) && !layout.hiddenTabs.contains($0.rawValue)
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
