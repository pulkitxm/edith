import AppKit
import EdithExtensionSupport
import EdithExtensionUI
@testable import HerdrUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrIntroductionButtonTests {
    static let variants =
        HerdrPageCaptureTests.Variant.all.filter { $0.name != "extra-wide-light" } + [
            HerdrPageCaptureTests.Variant(
                name: "zoom-light", size: CGSize(width: 1100, height: 760), dark: false,
                compact: false, scale: 1.6),
            HerdrPageCaptureTests.Variant(
                name: "compact-zoom-dark", size: CGSize(width: 900, height: 700), dark: true,
                compact: true, scale: 1.6),
        ]

    @Test func headerEndsWithTheIntroductionButton() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let guide = PageGuideAction(id: "herdr", title: "Agents") {}
        for variant in Self.variants {
            UIScale.apply(variant.scale)
            let suite = "HerdrIntroductionButtonTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            let store = HerdrStore(
                defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
            HerdrPageCaptureTests.prepare(store, .populated)
            let host = NSHostingView(
                rootView: AnyView(
                    HerdrPage(store: store, drag: HerdrDragCoordinator())
                        .environment(\.pageGuide, guide)
                        .environment(\.automaticViewActionsEnabled, false)
                        .environment(\.terminalLaunchEnabled, false)
                        .environment(\.compactLayout, variant.compact)
                        .environment(\.colorScheme, variant.dark ? .dark : .light)
                        .environment(\.controlActiveState, .key)
                        .transaction { $0.animation = nil }))
            host.frame = CGRect(origin: .zero, size: variant.size)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<6 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(40))
            }
            try HerdrPageCaptureTests.capture(host, name: "herdr-guide-\(variant.name)")
            let frames = Self.frames(
                host, labels: ["About Agents", "Search", "Refresh", "Message"])
            let about = try #require(frames["About Agents"], "\(variant.name)")
            let search = try #require(frames["Search"], "\(variant.name)")
            #expect(about.width > 1, "\(variant.name)")
            #expect(abs(about.midY - search.midY) <= 1, "\(variant.name)")
            #expect(abs(about.width - search.width) <= 1, "\(variant.name)")
            #expect(abs(about.height - search.height) <= 1, "\(variant.name)")
            for (label, other) in frames where label != "About Agents" {
                #expect(about.minX >= other.maxX - 0.5, "\(variant.name) \(label)")
            }
            store.closeAll()
            window.contentView = nil
        }
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
