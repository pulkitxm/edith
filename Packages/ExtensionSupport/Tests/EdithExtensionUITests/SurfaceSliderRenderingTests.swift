import AppKit
import EdithExtensionSupport
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
extension SurfaceGridRenderingTests {
    @Test func controlsStayInsideCompactAndZoomedCardsAndHiddenFieldsRemoveThem() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let priorAccessibility = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, prior) in zip(attributes, priorAccessibility) {
                NSApp.accessibilitySetValue(prior ?? false, forAttribute: attribute)
            }
        }
        var commits = 0
        let snapshot = SurfaceSnapshot(
            providerID: "music",
            sliders: [
                .init("volume", "Synthetic volume", "speaker.wave.2", value: 0.7, field: "volume")
            ])
        for width in [320.0, 780.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let tile = SurfaceTile(.music)
                    let host = NSHostingView(
                        rootView: SurfaceSnapshotContent(
                            tile: tile, snapshot: snapshot, perform: { _ in },
                            adjust: { _, _ in commits += 1 }
                        ).padding(16).environment(\.colorScheme, scheme))
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 240)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host; window.orderBack(nil)
                    defer { window.orderOut(nil) }
                    for _ in 0..<5 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let slider = try #require(find(host, label: "Synthetic volume"))
                    let frame = (slider as AnyObject).accessibilityFrame?() ?? .zero
                    #expect(frame.width > 0 && frame.width <= width)
                    #expect(frame.minX >= window.frame.minX && frame.maxX <= window.frame.maxX)
                    var hidden = tile; hidden.hiddenFields = ["volume"]
                    let restricted = NSHostingView(
                        rootView: SurfaceSnapshotContent(
                            tile: hidden, snapshot: snapshot, perform: { _ in },
                            adjust: { _, _ in commits += 1 }))
                    restricted.frame = host.frame; window.contentView = restricted
                    restricted.layoutSubtreeIfNeeded()
                    #expect(find(restricted, label: "Synthetic volume") == nil)
                }
            }
        }
        #expect(commits == 0)
    }

    private func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label,
            (node as AnyObject).accessibilityRole?() == NSAccessibility.Role.slider
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = find(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
