import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing
import Vision
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
                            .environment(\.colorScheme, scheme)
                            .transaction { $0.animation = nil }
                            .frame(width: width, height: 900)
                            .background(UsageExtension.DashSkin.paper(scheme == .dark)))
                    host.sizingOptions = []
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    let window = UsageRenderWindow(
                        contentRect: host.frame, styleMask: [.titled], backing: .buffered,
                        defer: false)
                    window.setFrameOrigin(
                        NSPoint(
                            x: (NSScreen.screens.map { $0.frame.minX }.min() ?? 0) - width - 1_000,
                            y: (NSScreen.screens.map { $0.frame.minY }.min() ?? 0) - 1_900))
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

    @Test func nativeHomeCardsAndSettingsRenderWithoutAutomaticActions() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let client = UsageUIClient(invoke: { _, _ in throw ExtensionPeerError.unavailable })
        UsageUIClient.current = client
        defer { client.stop(); UsageUIClient.current = nil }
        let model = DashboardModel()
        defer { model.shutdown() }
        let today = CalendarDay.stamp(Date())
        let data = try JSONSerialization.data(withJSONObject: [
            "sources": ["sample"], "defaultSources": ["sample"],
            "daily": [
                [
                    "period": today,
                    "bySource": [
                        "sample": [
                            [
                                "modelName": "Sample model", "inputTokens": 25_000_000,
                                "outputTokens": 1_700_000, "cacheReadTokens": 5_000_000, "cost": 0,
                            ]
                        ]
                    ],
                ]
            ],
        ])
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: data))
        await model.awaitPendingComputation()
        let detail = try #require(model.heatDetail[today])
        #expect(detail.tokens == 31_700_000 && detail.cost == 0)
        let usageTile = SurfaceTile(.usage)
        let snapshot = SurfaceUsageSnapshot(
            document: try JSONDecoder().decode(SurfaceUsageDocument.self, from: data),
            tile: usageTile)
        for width in [430.0, 1_100.0] {
            for zoom in [1.0, 1.5] {
                UIScale.apply(zoom)
                for scheme in [ColorScheme.light, .dark] {
                    let views: [(AnyView, String)] = [
                        (
                            AnyView(
                                UsageHomeActivityCard(tile: SurfaceTile(.activity), model: model)),
                            "Usage activity"
                        ),
                        (AnyView(UsageHomeUsageCard(tile: usageTile, snapshot: snapshot)), "Today"),
                        (AnyView(UsageHomeScene(tile: SurfaceTile(.limits))), "Rate limits"),
                        (
                            AnyView(Form { UsageSettingsRows() }.formStyle(.grouped)),
                            "Claude limits"
                        ),
                    ]
                    for (view, label) in views {
                        let host = NSHostingView(
                            rootView:
                                view
                                .environment(\.automaticViewActionsEnabled, false)
                                .environment(\.compactLayout, width < 700)
                                .environment(\.colorScheme, scheme)
                                .transaction { $0.animation = nil }
                                .frame(width: width, height: 900)
                                .background(UsageExtension.DashSkin.paper(scheme == .dark)))
                        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        host.sizingOptions = []
                        host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                        let window = UsageRenderWindow(
                            contentRect: host.frame,
                            styleMask: [.titled], backing: .buffered, defer: false)
                        window.setFrameOrigin(
                            NSPoint(
                                x: (NSScreen.screens.map { $0.frame.minX }.min() ?? 0) - width
                                    - 1_000,
                                y: (NSScreen.screens.map { $0.frame.minY }.min() ?? 0) - 1_900))
                        window.isReleasedWhenClosed = false
                        window.contentView = host
                        window.orderBack(nil)
                        defer { window.orderOut(nil); window.contentView = nil; window.close() }
                        for _ in 0..<6 {
                            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        let bitmap = try #require(
                            host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        #expect(png.count > 1_000)
                        let image = try #require(bitmap.cgImage)
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        try VNImageRequestHandler(cgImage: image).perform([recognition])
                        let heading = try #require(
                            recognition.results?.first(where: {
                                $0.topCandidates(1).first?.string.localizedCaseInsensitiveContains(
                                    label) == true
                            }), Comment(rawValue: label))
                        #expect(heading.boundingBox.minX > 0 && heading.boundingBox.maxX < 1)
                        #expect((heading.topCandidates(1).first?.confidence ?? 0) > 0.25)
                    }
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
