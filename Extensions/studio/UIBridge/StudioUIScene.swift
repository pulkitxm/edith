import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor final class StudioUIScene {
    enum Route: Equatable {
        case main, settings

        init?(context: NSDictionary) {
            guard context["tile"] == nil, context["target"] == nil else { return nil }
            switch (context["location"] as? String, context["section"] as? String) {
            case ("main", "studio"): self = .main
            case ("settings", "extension"): self = .settings
            default: return nil
            }
        }
    }

    let route: Route
    let model: StudioModel
    private let privacy: SurfacePrivacyState?

    init(client: ExtensionEngineClient, route: Route) {
        self.route = route
        model = StudioModel(
            loadsState: false,
            facade: StudioUIFacade(client: client, settingsOnly: route == .settings))
        privacy =
            route == .main
            ? ExtensionSharedState.current.map(SurfacePrivacyState.init(channel:)) : nil
    }

    func controller() -> NSViewController {
        switch route {
        case .main:
            return NSHostingController(
                rootView: ExtensionPageHost {
                    StudioPage(model: self.model).environment(\.studioPrivacy, self.privacy)
                        .environment(\.studioFacade, self.model.facade)
                        .onAppear { TextEditingCommands.install() }
                })
        case .settings:
            return NSHostingController(
                rootView: ExtensionPageHost { StudioSettingsScene(model: self.model) })
        }
    }

    func synchronize() {
        privacy?.refresh()
        if route == .settings { model.facade?.refresh() }
    }

    func stop() {
        model.shutdown()
        privacy?.shutdown()
    }
}
