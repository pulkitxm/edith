import Foundation
import Testing

@Suite struct DashboardPopoverTests {
    @Test func activityPopoverUsesTheHoveredCellAsItsSource() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Dashboard/Views/DashboardView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let heatmapStart = try #require(source.range(of: "struct ActivityHeatmap"))
        let heatmapEnd = try #require(
            source.range(
                of: "private struct HeatCellView",
                range: heatmapStart.upperBound..<source.endIndex))
        let heatmap = String(source[heatmapStart.lowerBound..<heatmapEnd.lowerBound])

        let cell = try #require(heatmap.range(of: "HeatCellView("))
        let hover = try #require(
            heatmap.range(of: ".onHover", range: cell.upperBound..<heatmap.endIndex))
        let popover = try #require(
            heatmap.range(of: ".popover(", range: hover.upperBound..<heatmap.endIndex))

        #expect(cell.lowerBound < hover.lowerBound)
        #expect(hover.lowerBound < popover.lowerBound)
        #expect(heatmap.contains("get: { hovered?.id == day.id }"))
        #expect(heatmap.contains("if let hovered, hovered.id == day.id"))
        #expect(!heatmap.contains(".frame(height: UIScale.pt(137))\n        .popover"))
    }
}
