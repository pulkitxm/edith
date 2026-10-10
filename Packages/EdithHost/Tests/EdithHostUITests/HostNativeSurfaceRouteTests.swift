import EdithExtensionSupport
import Testing

@testable import EdithHost

struct HostNativeSurfaceRouteTests {
    @Test func onlyOwnedOriginalHomeCardsReceiveNativeRoutes() {
        for (provider, widget, section) in [
            ("music", SurfaceWidget.music, "music"), ("calendar", .calendar, "calendar"),
            ("attention", .focus, "focus"),
        ] {
            var tile = SurfaceTile(widget)
            tile.title = "Synthetic customized title"
            tile.sourceIDs = ["synthetic-source"]
            tile.itemLimit = 4
            #expect(
                HostNativeSurfaceRoute.section(provider: provider, target: .home, tile: tile)
                    == section)
            #expect(
                HostNativeSurfaceRoute.section(provider: provider, target: .notch, tile: tile)
                    == nil)
            #expect(
                HostNativeSurfaceRoute.section(provider: "focusDim", target: .home, tile: tile)
                    == nil)
            #expect(
                HostNativeSurfaceRoute.section(
                    provider: provider, target: .home, tile: SurfaceTile(.ability(provider))) == nil
            )
        }
        for widget in [SurfaceWidget.desk, .actions, .clocks, .usage, .agents, .calendar] {
            #expect(
                HostNativeSurfaceRoute.section(
                    provider: "music", target: .home, tile: SurfaceTile(widget)) == nil)
        }
    }
}
