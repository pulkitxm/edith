import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor
extension SurfaceGridRenderingTests {
    @Test func favoritesAndContentOptionsRenderInBothSurfaces() async throws {
        let suite = "surface-clocks-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Asia/Kolkata,Asia/Tokyo", forKey: AppStorageKeys.General.homeClockZones)
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        let previousScale = UIScale.current
        defer {
            UIScale.apply(previousScale)
            for (attribute, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            for width in [420.0, 780.0] {
                for zoom in [1.0, 1.5] {
                    UIScale.apply(zoom)
                    var tile = SurfaceTile(.clocks)
                    tile.itemLimit = 3
                    tile.showActions = false
                    let host = NSHostingView(
                        rootView: ScrollView {
                            SurfaceWorldClocks(tile: tile, defaults: defaults)
                        }.environment(\.compactLayout, width < 720)
                            .environment(\.colorScheme, scheme)
                            .frame(width: width, height: 520))
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 520)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.contentView = host
                    window.orderBack(nil)
                    defer { window.orderOut(nil) }
                    for _ in 0..<8 {
                        window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    host.displayIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        if let path = ProcessInfo.processInfo.environment[
                            "EDITH_TEST_CAPTURE_CLOCKS"],
                            let data = bitmap.representation(using: .png, properties: [:])
                        {
                            let directory = URL(fileURLWithPath: path, isDirectory: true)
                            try FileManager.default.createDirectory(
                                at: directory, withIntermediateDirectories: true)
                            try data.write(
                                to: directory.appendingPathComponent(
                                    "clocks-\(scheme)-\(Int(width))-\(zoom).png"), options: .atomic)
                        }
                    }
                    let labels = accessibleLabels(host)
                    #expect(abs(host.bounds.width - width) < 1)
                    #expect(labels.contains { $0.hasPrefix("Local,") })
                    #expect(labels.contains { $0.hasPrefix("Kolkata,") })
                    #expect(labels.contains { $0.hasPrefix("Tokyo,") })
                    #expect(!labels.contains("Add city"))
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(
                        defaults.string(forKey: AppStorageKeys.General.homeClockZones)
                            == "Asia/Kolkata,Asia/Tokyo")
                }
            }
        }
    }

    private func accessibleLabels(_ node: AnyObject, depth: Int = 0) -> [String] {
        guard depth < 64 else { return [] }
        var result = [(node as AnyObject).accessibilityLabel?()].compactMap { $0 }
        let value = NSSelectorFromString("accessibilityValue")
        if let object = node as? NSObject, object.responds(to: value),
            let text = object.perform(value)?.takeUnretainedValue() as? String
        {
            result.append(text)
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [AnyObject] ?? [] {
            result += accessibleLabels(child, depth: depth + 1)
        }
        return result
    }
}
