import Foundation
import Testing

@testable import Edith

@Suite struct DashboardScalabilityTests {
    @Test func denseViewsStayBoundedAndChartsLoadOnDemand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith/Features/Dashboard/Views")
        let dashboard = try String(
            contentsOf: root.appendingPathComponent("DashboardView.swift"), encoding: .utf8)
        let charts = try String(
            contentsOf: root.appendingPathComponent("DashboardCharts.swift"), encoding: .utf8)
        let skin = try String(
            contentsOf: root.appendingPathComponent("DashboardSkin.swift"), encoding: .utf8)

        #expect(dashboard.contains("LazyChartCard(title: \"Daily usage\""))
        #expect(dashboard.contains("LazyVStack(spacing: UIScale.pt(16))"))
        #expect(
            dashboard.contains(
                "model.modelTotals.count > DashboardChartLayout.visibleModelRows"))
        #expect(dashboard.contains("model.allSources.count > 3"))
        #expect(dashboard.contains("if !compactLayout"))
        #expect(charts.contains("ViewThatFits(in: .horizontal)"))
        #expect(charts.contains(".chartLegend(.hidden)"))
        #expect(
            charts.components(separatedBy: "y: .fit(to: .chart)").count == 3)
        #expect(skin.contains("await Task.yield()"))
    }
}
