import EdithKit
import Testing

@Suite struct SurfaceArrangementTests {
    @Test func automaticRowsBalanceChangingWidgetCounts() {
        #expect(SurfaceArrangement.rowCounts(count: 0, width: 1200, gap: 12).isEmpty)
        #expect(SurfaceArrangement.rowCounts(count: 4, width: 1200, gap: 12) == [2, 2])
        #expect(SurfaceArrangement.rowCounts(count: 5, width: 1200, gap: 12) == [3, 2])
        #expect(SurfaceArrangement.rowCounts(count: 7, width: 1200, gap: 12) == [3, 2, 2])
        #expect(SurfaceArrangement.rowCounts(count: 3, width: 600, gap: 12) == [1, 1, 1])
        #expect(SurfaceArrangement.rowCounts(count: 3, width: .infinity, gap: 12) == [1, 1, 1])
        #expect(SurfaceArrangement.rowCounts(count: 3, width: .nan, gap: 12) == [1, 1, 1])
        #expect(
            SurfaceArrangement.rowCounts(
                count: 5, width: 1200, minimumWidth: 130, maximumColumns: 5, gap: 12) == [5])
    }
    @Test func shelfFillsAvailableSpaceAndHonorsExplicitWidths() {
        let tiles = [SurfaceTile(.music), SurfaceTile(.actions)]
        let widths = SurfaceArrangement.shelfWidths(
            tiles: tiles, available: 1000, preferred: 280, gap: 12)
        #expect(widths == [494, 494])
        var customized = tiles
        customized[0].shelfWidth = 340
        #expect(
            SurfaceArrangement.shelfWidths(
                tiles: customized, available: 1000,
                preferred: 280, gap: 12) == [340, 648])
        let overflowing = SurfaceArrangement.shelfWidths(
            tiles: tiles + tiles, available: 600,
            preferred: 280, gap: 12)
        #expect(overflowing == [294, 294, 294, 294])
    }
    @Test func presetsConfigureContentGeometryAndGlances() {
        let agents = SurfacePreset.agents.layout(for: .notch)
        #expect(agents.tiles.first?.widget == .agents)
        #expect(agents.tiles.first?.itemLimit == 20)
        #expect(agents.notchLeadingGlance == .workingAgents)
        #expect(agents.notchTrailingGlance == .permissions)
        #expect(agents.notchAgentSources == nil)
        #expect(agents.notchIncludeSubagents)
        #expect(SurfacePreset.media.layout(for: .notch).notchLeadingGlance == .music)
        for preset in SurfacePreset.allCases {
            let layout = preset.layout(for: .notch)
            #expect(layout == SurfaceLayout.decode(layout.encoded, target: .notch))
            #expect(layout.notchHorizontal)
        }
    }
    @Test func notchGrowsToShowControlsAndManualWidthRemainsAvailable() {
        var layout = SurfaceLayout(tiles: [.init(.actions)])
        #expect(layout.expandedNotchWidth == 580)
        layout.add(.music); layout.add(.limits)
        #expect(layout.expandedNotchWidth == 912)
        layout.notchAutoWidth = false
        #expect(layout.expandedNotchWidth == 580)
        layout.notchAutoWidth = true
        layout.tiles[0].shelfWidth = 760
        #expect(layout.expandedNotchWidth == 1200)
    }
    @Test func manualPositionsKeepThePreciseGrid() {
        var layout = SurfaceLayout.standard(.home)
        #expect(layout.usesBalancedRows)
        layout.tiles[0].column = 4
        #expect(!layout.usesBalancedRows)
        layout.arrangeAutomatically()
        #expect(layout.usesBalancedRows)
    }
}
