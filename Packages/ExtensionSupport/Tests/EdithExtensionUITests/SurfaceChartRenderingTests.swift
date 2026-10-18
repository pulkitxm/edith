import AppKit
import EdithExtensionSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
extension SurfaceGridRenderingTests {
    @Test func genericChartsRenderCompactAndZoomedStylesAndRespectHiddenFields() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, prior) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        for style in [SurfaceChartStyle.bar, .line, .area] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for dense in [false, true] {
                    var tile = SurfaceTile(.usage)
                    tile.dense = dense; tile.accentHex = "4C86B8"
                    let chart = SurfaceChart(
                        "daily", "Synthetic daily usage",
                        series: [
                            .init(
                                "cost", "Cost",
                                points: (0..<14).map {
                                    .init(
                                        String($0), x: 1_700_000_000 + Double($0) * 86_400,
                                        y: Double($0 % 5), label: "Synthetic day \($0)",
                                        value: "$\($0 % 5).00")
                                })
                        ], style: style, xAxis: .date, xTitle: "Day", yTitle: "Cost")
                    let snapshot = SurfaceSnapshot(providerID: "usage", charts: [chart])
                    let host = NSHostingView(
                        rootView: SurfaceSnapshotContent(
                            tile: tile, snapshot: snapshot, perform: { _ in }
                        ).environment(\.colorScheme, dense ? .dark : .light))
                    host.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host; window.orderBack(nil)
                    defer { window.orderOut(nil) }
                    for _ in 0..<4 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let visible = try #require(chartNode(host, label: chart.title))
                    let frame = (visible as AnyObject).accessibilityFrame?() ?? .zero
                    #expect(frame.width > 0 && frame.width <= 320)
                    #expect(frame.maxX <= window.frame.maxX && frame.minX >= window.frame.minX)
                    tile.hiddenFields = ["chart"]
                    let hidden = NSHostingView(
                        rootView: SurfaceSnapshotContent(
                            tile: tile, snapshot: snapshot, perform: { _ in }))
                    hidden.frame = host.frame; window.contentView = hidden
                    hidden.layoutSubtreeIfNeeded()
                    #expect(chartNode(hidden, label: chart.title) == nil)
                }
            }
        }
    }

    private func chartNode(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = chartNode(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
