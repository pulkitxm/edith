import Foundation
import Testing

@testable import EdithKit

struct SurfaceLayoutTests {
    @Test func placementPreservesConfigurationAndHasStableInsertion() {
        var layout = SurfaceLayout.standard(.home)
        layout.tiles[0].title = "Across the world"
        layout.place(.clocks, before: SurfaceWidget.usage.id)
        #expect(
            layout.tiles.map(\.widget) == [
                .actions, .activity, .calendar, .clocks, .usage, .limits, .music, .codeStats,
            ])
        #expect(layout.tiles.first { $0.widget == .clocks }?.title == "Across the world")
        layout.place(.focus, before: SurfaceWidget.actions.id)
        #expect(layout.tiles.first?.widget == .focus)
        layout.place(.focus)
        #expect(layout.tiles.last?.widget == .focus)
        #expect(layout.tiles.filter { $0.widget == .focus }.count == 1)
    }

    @Test func normalizedLayoutRejectsDuplicatesAndBoundsSettings() {
        var tile = SurfaceTile(.focus)
        tile.focusMinutes = -100
        tile.title = String(repeating: "a", count: 200)
        tile.days = 0
        let layout = SurfaceLayout(tiles: [tile, tile]).normalized()
        #expect(layout.tiles.count == 1)
        #expect(layout.tiles[0].focusMinutes == 1)
        #expect(layout.tiles[0].days == 30)
        #expect(layout.tiles[0].title.count == 64)
        #expect(SurfaceLayout.decode(layout.encoded, target: .home) == layout)
        #expect(SurfaceLayout.decode("broken", target: .notch) == .standard(.notch))
        #expect(SurfaceLayout.decode(SurfaceLayout(tiles: []).encoded, target: .home).tiles.isEmpty)
    }

    @Test func tabsKeepHomeReachableAndRestoreHiddenWidgetsOnDrop() {
        var layout = SurfaceLayout.standard(.notch)
        layout.tabOrder = ["camera", "camera", "unknown"]
        layout.hiddenTabs = ["home", "camera", "unknown"]
        layout.tiles[0].hidden = true
        let normalized = layout.normalized()
        #expect(normalized.tabOrder.first == "camera")
        #expect(Set(normalized.tabOrder) == Set(SurfaceNotchTab.allCases.map(\.rawValue)))
        #expect(normalized.hiddenTabs == ["camera"])
        layout.place(.music)
        #expect(layout.visible.last?.widget == .music)
    }

    @Test func rowsHonorOrderWideTilesAndHiddenTiles() {
        var hidden = SurfaceTile(.calendar)
        hidden.hidden = true
        let layout = SurfaceLayout(tiles: [
            .init(.music), .init(.limits), .init(.actions, size: .wide), hidden, .init(.focus),
        ])
        #expect(
            layout.rows(singleColumn: false).map { $0.map(\.widget) } == [
                [.music, .limits], [.actions], [.focus],
            ])
        #expect(
            layout.rows(singleColumn: true).map { $0.map(\.widget) } == [
                [.music], [.limits], [.actions], [.focus],
            ])
    }

    @MainActor @Test func historyAndExternalChangesStayIndependentAcrossSurfaces() throws {
        let domain = "test.surface-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SurfaceLayoutStore(defaults: defaults)
        store.update(.notch) { $0.place(.focus) }
        store.update(.home) { $0.tiles = [] }
        store.undo(.notch)
        #expect(store.notch == .standard(.notch))
        #expect(store.home.tiles.isEmpty)
        store.redo(.notch)
        #expect(store.notch.tiles.last?.widget == .focus)
        #expect(SurfaceLayoutStore(defaults: defaults).notch == store.notch)
        defaults.set(
            SurfaceLayout(tiles: [.init(.agents)]).encoded, forKey: SurfaceTarget.notch.key)
        store.reload()
        #expect(store.notch.tiles.map(\.widget) == [.agents])
        #expect(!store.canUndo(.notch))
        #expect(store.canUndo(.home))
    }
}
