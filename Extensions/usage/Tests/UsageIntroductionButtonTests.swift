import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized)
struct UsageIntroductionButtonTests {
    static let variants =
        UsageDashboardCaptureTests.variants + [
            UsageDashboardCaptureTests.zoomed,
            UsageDashboardCaptureTests.Variant(
                name: "zoom-dark", size: CGSize(width: 1100, height: 760), scheme: .dark, zoom: 1.6),
        ]

    @Test func mastheadEndsWithTheIntroductionButton() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let scene = try await UsageDashboardCaptureTests.scene(.populated)
        let guide = PageGuideAction(id: "usage", title: "Agent Usage") {}
        for variant in Self.variants {
            UIScale.apply(variant.zoom)
            let view = DashboardView(model: scene.model, client: scene.client)
                .environment(\.pageGuide, guide)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.compactLayout, variant.size.width < UIScale.pt(720))
                .environment(\.colorScheme, variant.scheme)
                .transaction { $0.animation = nil }
            let (window, host) = UsageScrollHarness.host(view, size: variant.size)
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
            await UsageScrollHarness.settle(host, for: .milliseconds(500))
            Self.capture(host, name: "usage-guide-\(variant.name)")
            let frames = Self.frames(
                host, labels: ["About Agent Usage", "Share usage cards", "Collect new usage now"])
            let about = try #require(frames["About Agent Usage"], "\(variant.name)")
            let refresh = try #require(frames["Collect new usage now"], "\(variant.name)")
            #expect(about.width > 1, "\(variant.name)")
            #expect(abs(about.midY - refresh.midY) <= 1, "\(variant.name)")
            #expect(abs(about.width - refresh.width) <= 0.5, "\(variant.name)")
            #expect(abs(about.height - refresh.height) <= 0.5, "\(variant.name)")
            for (label, other) in frames where label != "About Agent Usage" {
                #expect(about.minX >= other.maxX - 0.5, "\(variant.name) \(label)")
            }
        }
    }

    static func capture(_ host: NSView, name: String) {
        guard let root = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"],
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(
            to: directory.appendingPathComponent(name + ".png"))
    }

    static func frames(_ host: NSView, labels: [String]) -> [String: CGRect] {
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
        var result: [String: CGRect] = [:]
        for label in labels {
            if let node = find(host, label: label),
                let frame = (node as AnyObject).accessibilityFrame?()
            {
                result[label] = frame
            }
        }
        return result
    }

    static func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        for child in (node as? NSView)?.subviews ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }
}
