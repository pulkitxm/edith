import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
final class CalendarUIPresentation {
    let facade: CalendarUIFacade
    private let location: String
    private let tile: SurfaceTile?

    convenience init?(client: ExtensionEngineClient, context: NSDictionary) {
        guard context["section"] as? String == "calendar",
            let location = context["location"] as? String,
            location == "main" || location == "home"
        else { return nil }
        var tile: SurfaceTile?
        if location == "home" {
            guard let data = context["tile"] as? Data, data.count <= 65_536,
                let value = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                value.widget == .calendar,
                (try? SurfaceSnapshotRequest(target: .home, tile: value).encoded(
                    providerID: "calendar")) != nil
            else { return nil }
            tile = value
        } else if context["tile"] != nil {
            return nil
        }
        self.init(facade: CalendarUIFacade(client: client), location: location, tile: tile)
    }

    init(facade: CalendarUIFacade, location: String, tile: SurfaceTile? = nil) {
        self.facade = facade
        self.location = location
        self.tile = tile
    }

    func matches(_ context: NSDictionary) -> Bool {
        guard context["location"] as? String == location,
            context["section"] as? String == "calendar"
        else { return false }
        if let tile {
            guard let data = context["tile"] as? Data, data.count <= 65_536,
                let value = try? JSONDecoder().decode(SurfaceTile.self, from: data)
            else { return false }
            return tile == value
        }
        return context["tile"] == nil
    }

    func controller() -> NSViewController {
        let facade = self.facade
        if let tile {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    CalendarHomeScene(tile: tile, store: facade, open: facade.openPage)
                })
        }
        return NSHostingController(rootView: ExtensionPageHost { CalendarPage(store: facade) })
    }

    func shutdown() { facade.shutdown() }
}
