import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import UsageExtension

extension UsageDashboardCaptureTests {
    static let rangeSelections: [(name: String, selection: DateFilterSelection)] = [
        ("1d", .preset(.today)), ("7d", .preset(.last7)), ("30d", .preset(.last30)),
        ("90d", .preset(.last90)), ("1y", .preset(.last12Months)), ("all", .preset(.allTime)),
    ]

    static let rangeVariants = [
        Variant(name: "compact-dark", size: CGSize(width: 640, height: 1400), scheme: .dark),
        Variant(name: "regular-light", size: CGSize(width: 1100, height: 1200), scheme: .light),
        Variant(name: "wide-dark", size: CGSize(width: 2000, height: 1200), scheme: .dark),
        Variant(
            name: "wide-zoomed-light", size: CGSize(width: 2000, height: 1400), scheme: .light,
            zoom: 1.6),
    ]

    struct ActivityProbe {
        var card: CGRect?
        var limits: CGRect?
        var cells: [CGRect] = []
    }

    static func activityProbe(_ host: NSView) -> ActivityProbe {
        var probe = ActivityProbe()
        func visit(_ node: NSObject, depth: Int) {
            guard depth < 64 else { return }
            let object = node as AnyObject
            let label = object.accessibilityLabel?() ?? ""
            if object.accessibilityIdentifier?() == "usage-activity" {
                probe.card = object.accessibilityFrame?()
            }
            if object.accessibilityIdentifier?() == "usage-rate-limits" {
                probe.limits = object.accessibilityFrame?()
            }
            if label.hasPrefix("Activity "), label != "Activity calendar",
                let frame = object.accessibilityFrame?()
            {
                probe.cells.append(frame)
            }
            for child in object.accessibilityChildren?() as? [NSObject] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(host, depth: 0)
        return probe
    }

    static func withManualAccessibility<T>(_ body: () async throws -> T) async rethrows -> T {
        _ = UsageScrollHarness.application
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
        return try await body()
    }

    @Test func activityCalendarKeepsSquareCellsAndItsFrameAtEveryRange() async throws {
        try await Self.withManualAccessibility {
            let previous = UIScale.current
            defer { UIScale.apply(previous) }
            let scene = try await Self.scene(.populated, days: 800)
            for variant in Self.rangeVariants {
                UIScale.apply(variant.zoom)
                var first: CGRect?
                for range in Self.rangeSelections {
                    scene.model.range = range.selection
                    await scene.model.awaitPendingComputation()
                    let probe = try await Self.probeActivity(
                        scene, variant: variant, name: "range-\(range.name)-\(variant.name)")
                    let label = "\(variant.name) \(range.name)"
                    let card = try #require(probe.card, "\(label) lost the activity card")
                    #expect(!probe.cells.isEmpty, "\(label) drew no activity cells")
                    for cell in probe.cells {
                        #expect(abs(cell.width - cell.height) <= 1, "\(label) cell \(cell.size)")
                        #expect(cell.width <= 28 * variant.zoom + 1, "\(label) cell \(cell.size)")
                    }
                    if let first {
                        #expect(
                            abs(first.minX - card.minX) <= 1 && abs(first.width - card.width) <= 1
                                && abs(first.height - card.height) <= 1,
                            "\(label) moved the activity card from \(first) to \(card)")
                    } else {
                        first = card
                    }
                }
            }
        }
    }

    @Test func activityCardStaysInsideAPageNarrowedByTheSidebar() async throws {
        try await Self.withManualAccessibility {
            let scene = try await Self.scene(.populated, days: 800)
            for range in Self.rangeSelections where ["90d", "1y", "all"].contains(range.name) {
                scene.model.range = range.selection
                await scene.model.awaitPendingComputation()
                for width in [420.0, 540, 660, 780, 900] {
                    let variant = Variant(
                        name: "sidebar-\(Int(width))", size: CGSize(width: width, height: 1400),
                        scheme: .dark)
                    let (probe, page) = try await Self.probeActivityFrame(
                        scene, variant: variant, compact: false,
                        name: "range-\(range.name)-\(variant.name)")
                    let label = "\(variant.name) \(range.name)"
                    let card = try #require(probe.card, "\(label) lost the activity card")
                    let limits = try #require(probe.limits, "\(label) lost the rate limits")
                    for (name, frame) in [("activity card", card), ("rate limits", limits)] {
                        #expect(
                            frame.minX >= page.minX - 1 && frame.maxX <= page.maxX + 1,
                            "\(label) \(name) \(frame) leaves the page \(page)")
                    }
                }
            }
        }
    }

    static func probeActivity(_ scene: Scene, variant: Variant, name: String) async throws
        -> ActivityProbe
    {
        try await probeActivityFrame(
            scene, variant: variant, compact: variant.size.width < UIScale.pt(720), name: name
        ).probe
    }

    static func probeActivityFrame(
        _ scene: Scene, variant: Variant, compact: Bool, name: String
    ) async throws -> (probe: ActivityProbe, page: CGRect) {
        let view = DashboardView(model: scene.model, client: scene.client)
            .environment(\.usageUIClient, scene.client)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.compactLayout, compact)
            .environment(\.colorScheme, variant.scheme)
            .transaction { $0.animation = nil }
        let (window, host) = UsageScrollHarness.host(view, size: variant.size)
        defer { window.orderOut(nil) }
        host.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        await UsageScrollHarness.settle(host, for: .milliseconds(400))
        _ = host.accessibilityChildren()
        await UsageScrollHarness.settle(host, for: .milliseconds(200))
        let probe = activityProbe(host)
        if let root = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let directory = URL(fileURLWithPath: root)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("usage-\(name).png"))
        }
        return (probe, window.frame)
    }
}
