import EdithExtensionSupport
import EdithExtensionUI
import Testing

@testable import EdithHost

struct HostNativeSurfaceRouteTests {
    @Test func onlyOwnedOriginalHomeCardsReceiveNativeRoutes() {
        for (provider, widget, section) in [
            ("music", SurfaceWidget.music, "music"), ("calendar", .calendar, "calendar"),
            ("attention", .focus, "focus"),
            ("usage", .usage, "usage"), ("usage", .activity, "activity"),
            ("usage", .limits, "limits"),
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

    @Test func nativeRequestsCarryResolvedCustomizationWithoutChangingTheSavedTile() throws {
        for widget in [SurfaceWidget.usage, .activity, .limits, .music, .calendar, .focus] {
            var tile = SurfaceTile(widget)
            tile.title = "Synthetic customized card"
            tile.sourceIDs = ["synthetic-source"]
            tile.itemLimit = 4
            tile.showActions = false
            var layout = SurfaceLayout(tiles: [tile])
            layout.padding = 22
            layout.cornerRadius = 7
            let request = HostNativeSurfaceRoute.request(
                target: .home, tile: tile,
                presentation: SurfacePresentation(tile: tile, layout: layout))
            #expect(request.tile.paddingOverride == 22 && request.tile.cornerOverride == 7)
            #expect(tile.paddingOverride == nil && tile.cornerOverride == nil)
            var expected = tile
            expected.paddingOverride = 22
            expected.cornerOverride = 7
            #expect(request.tile == expected)
            for provider in widget.providerIDs {
                #expect(
                    try SurfaceSnapshotRequest.decode(
                        request.encoded(providerID: provider), providerID: provider) == request)
            }
            tile.dense = true
            #expect(
                HostNativeSurfaceRoute.request(
                    target: .home, tile: tile,
                    presentation: SurfacePresentation(tile: tile, layout: layout)
                ).tile.paddingOverride == 10)
            tile.paddingOverride = 18
            tile.cornerOverride = 9
            let custom = HostNativeSurfaceRoute.request(
                target: .home, tile: tile,
                presentation: SurfacePresentation(tile: tile, layout: layout))
            #expect(custom.tile == tile)
            #expect(
                HostNativeSurfaceRoute.request(target: .home, tile: tile, presentation: nil).tile
                    == tile)
            let foreign = SurfacePresentation(tile: SurfaceTile(.clocks), layout: layout)
            #expect(
                HostNativeSurfaceRoute.request(target: .home, tile: tile, presentation: foreign)
                    .tile == tile)
        }
    }
}
