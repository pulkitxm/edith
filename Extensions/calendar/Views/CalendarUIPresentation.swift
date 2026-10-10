import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct CalendarUISceneRoute: Equatable {
    enum Location: String {
        case main
        case home
        case notch
    }

    let location: Location
    let tile: SurfaceTile?

    var target: SurfaceTarget? {
        switch location {
        case .main: nil
        case .home: .home
        case .notch: .notch
        }
    }

    init(location: Location, tile: SurfaceTile? = nil) {
        self.location = location
        self.tile = tile
    }

    init?(context: NSDictionary) {
        guard context["section"] as? String == "calendar",
            let raw = context["location"] as? String, let location = Location(rawValue: raw)
        else { return nil }
        self.location = location
        if location == .main {
            guard context["tile"] == nil, context["target"] == nil else { return nil }
            tile = nil
        } else {
            guard context["target"] as? String == raw,
                let target = SurfaceTarget(rawValue: raw),
                let data = context["tile"] as? Data, data.count <= 65_536,
                let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                tile.widget == .calendar,
                (try? SurfaceSnapshotRequest(target: target, tile: tile).encoded(
                    providerID: "calendar")) != nil
            else { return nil }
            self.tile = tile
        }
    }
}

@MainActor
final class CalendarUIPresentation {
    private var pendingFacade: CalendarUIFacade?
    private weak var presentedFacade: CalendarUIFacade?
    var isRetained: Bool { pendingFacade != nil || presentedFacade != nil }
    private let route: CalendarUISceneRoute

    convenience init?(client: ExtensionEngineClient, context: NSDictionary) {
        guard let route = CalendarUISceneRoute(context: context) else { return nil }
        self.init(facade: CalendarUIFacade(client: client), route: route)
    }

    init(facade: CalendarUIFacade, route: CalendarUISceneRoute) {
        pendingFacade = facade
        self.route = route
    }

    func matches(_ context: NSDictionary) -> Bool {
        CalendarUISceneRoute(context: context) == route
    }

    func controller() -> NSViewController? {
        guard let facade = pendingFacade ?? presentedFacade else { return nil }
        presentedFacade = facade
        pendingFacade = nil
        switch route.location {
        case .main:
            return NSHostingController(rootView: ExtensionPageHost { CalendarPage(store: facade) })
        case .home:
            guard let tile = route.tile else { return nil }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    CalendarHomeScene(tile: tile, store: facade, open: facade.openPage)
                })
        case .notch:
            guard let tile = route.tile else { return nil }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    CalendarNotchScene(tile: tile, store: facade, open: facade.openPage)
                })
        }
    }

    func shutdown() {
        (pendingFacade ?? presentedFacade)?.shutdown()
        pendingFacade = nil
        presentedFacade = nil
    }
}
