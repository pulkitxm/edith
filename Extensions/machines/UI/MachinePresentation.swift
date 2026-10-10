import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor @Observable
final class MachinePrivacy {
    static let shared = MachinePrivacy()
    private var state: SurfacePrivacyState?

    var hidesMachines: Bool { state?.hides(.machines) ?? false }

    func start() {
        guard state == nil, let channel = ExtensionSharedState.current else { return }
        state = SurfacePrivacyState(channel: channel)
    }

    func shutdown() {
        state?.shutdown()
        state = nil
    }
}

private struct MachinePrivacyModifier: ViewModifier {
    @State private var privacy = MachinePrivacy.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.presenterCover(privacy.hidesMachines, dark: scheme == .dark)
    }
}

extension View {
    func machinePrivacyCover() -> some View { modifier(MachinePrivacyModifier()) }
}

enum MachineSettingsKeys {
    static let tab = "machinesTab"
    static let selection = "machinesSelection"
    static let mode = "machinesMode"
}

@MainActor enum WindowPresentation {
    static func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MachineNotifications {
    static func observe(
        _ name: String, info action: @escaping ([AnyHashable: Any]) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { notification in action(notification.userInfo ?? [:]) }
    }
}

enum MachineTableSizing {
    static func tableNameWidth(viewport: CGFloat, fixedWidth: Double, columnCount: Int) -> CGFloat {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return max(
            0,
            viewport - UIScale.pt(fixedWidth) - CGFloat(columnCount * 16 + 16) - scrollerWidth)
    }
}

enum MachineTerminalEnvironment {
    static func unnested(_ environment: [String]) -> [String] {
        let variables = TerminalLaunchPlan.nestingVariables
        return environment.filter { entry in
            !variables.contains(String(entry.prefix { $0 != "=" }))
        } + variables.map { $0 + "=" }
    }
}
