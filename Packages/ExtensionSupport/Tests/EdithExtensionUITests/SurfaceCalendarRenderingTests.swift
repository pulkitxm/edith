import AppKit
import EdithExtensionSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
extension SurfaceGridRenderingTests {
    @Test func calendarCellsRenderCompactAndZoomedAndRespectHiddenFields() async throws {
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
        for width in [240.0, 580.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for dense in [false, true] {
                    var tile = SurfaceTile(.usage)
                    tile.dense = dense; tile.accentHex = "4C86B8"
                    let descriptor = SurfaceCalendar(
                        "activity", "Synthetic activity",
                        days: (1...28).map {
                            .init(
                                String($0), date: String(format: "2026-02-%02d", $0), level: $0 % 5,
                                value: "Sample \($0)")
                        })
                    let snapshot = SurfaceSnapshot(providerID: "usage", calendars: [descriptor])
                    let host = NSHostingView(
                        rootView: SurfaceSnapshotContent(
                            tile: tile, snapshot: snapshot, perform: { _ in }
                        ).environment(\.colorScheme, dense ? .dark : .light))
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 240)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host; window.orderBack(nil)
                    defer { window.orderOut(nil) }
                    for _ in 0..<4 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let visible = try #require(calendarNode(host, label: descriptor.title))
                    let frame = (visible as AnyObject).accessibilityFrame?() ?? .zero
                    #expect(frame.width > 0 && frame.width <= width)
                    #expect(frame.maxX <= window.frame.maxX && frame.minX >= window.frame.minX)
                    tile.hiddenFields = ["chart"]
                    let hidden = NSHostingView(
                        rootView: SurfaceSnapshotContent(
                            tile: tile, snapshot: snapshot, perform: { _ in }))
                    hidden.frame = host.frame; window.contentView = hidden
                    hidden.layoutSubtreeIfNeeded()
                    #expect(calendarNode(hidden, label: descriptor.title) == nil)
                }
            }
        }
    }

    private func calendarNode(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = calendarNode(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
