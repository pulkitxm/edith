import AppKit
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageDashboardRenderingTests {
    @Test func fullDashboardRendersSyntheticUsageAtCompactRegularAndZoomedSizes() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        let zoom = UIScale.current
        defer {
            UIScale.apply(zoom)
            for (attribute, value) in zip(attributes, prior) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        let data = Data(
            #"{"sources":["fixture"],"defaultSources":["fixture"],"sourceMeta":{"fixture":{"label":"Sample source"}},"sessions":[],"daily":[{"period":"2026-10-09","bySource":{"fixture":[{"modelName":"Sample model","inputTokens":120,"outputTokens":30,"cost":2}]},"projects":[],"hours":[]}] }"#
                .utf8)
        let model = DashboardModel()
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: data))
        await model.awaitPendingComputation()
        defer { model.shutdown() }
        for width in [430.0, 1_100.0] {
            for scale in [1.0, 1.5] {
                UIScale.apply(scale)
                for scheme in [ColorScheme.light, .dark] {
                    let host = NSHostingView(
                        rootView: DashboardView(model: model)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.compactLayout, width < 700)
                            .environment(\.colorScheme, scheme))
                    host.sizingOptions = []
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    let window = UsageRenderWindow(
                        contentRect: host.frame, styleMask: [.titled], backing: .buffered,
                        defer: false)
                    window.setFrameOrigin(NSPoint(x: -2_000 - width, y: -2_000))
                    window.isReleasedWhenClosed = false; window.contentView = host;
                    window.orderBack(nil)
                    for _ in 0..<6 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded();
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let heading = try #require(node(host, text: "Agent usage"))
                    let frame = (heading as AnyObject).accessibilityFrame?() ?? .zero
                    #expect(frame.width > 0 && frame.width <= width)
                    #expect(frame.minX >= window.frame.minX && frame.maxX <= window.frame.maxX)
                    window.orderOut(nil); window.contentView = nil
                }
            }
        }
    }

    private func node(_ value: NSObject, text: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if ((value as AnyObject).accessibilityLabel?() ?? "").contains(text) {
            return value
        }
        for child in (value as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = node(child, text: text, depth: depth + 1) { return found }
        }
        return nil
    }
}

private final class UsageRenderWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
