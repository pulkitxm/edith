import AppKit
import CoreGraphics
import EdithExtensionSupport
import ImageIO
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor
extension SurfaceGridRenderingTests {
    @Test func thumbnailsStayBoundedAndHiddenArtworkLeavesNoAccessibleImage() async throws {
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
        let context = try #require(
            CGContext(
                data: nil, width: 160, height: 80, bitsPerComponent: 8, bytesPerRow: 640,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let snapshot = SurfaceSnapshot(
            providerID: "music",
            rows: [
                .init(
                    "track", title: "Synthetic track",
                    thumbnail: .init(
                        data: data as Data, accessibilityLabel: "Synthetic artwork",
                        field: "artwork"))
            ])
        for zoom in [1.0, 1.5] {
            UIScale.apply(zoom)
            var tile = SurfaceTile(.music)
            let host = NSHostingView(
                rootView: SurfaceSnapshotContent(tile: tile, snapshot: snapshot, perform: { _ in }))
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host; window.orderBack(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let image = try #require(thumbnailNode(host, label: "Synthetic artwork"))
            let bounds = (image as AnyObject).accessibilityFrame?() ?? .zero
            #expect(bounds.width > 0 && bounds.width <= UIScale.pt(52))
            #expect(bounds.height > 0 && bounds.height <= UIScale.pt(52))
            tile.hiddenFields = ["artwork"]
            let restricted = NSHostingView(
                rootView: SurfaceSnapshotContent(tile: tile, snapshot: snapshot, perform: { _ in }))
            restricted.frame = host.frame; window.contentView = restricted
            restricted.layoutSubtreeIfNeeded()
            #expect(thumbnailNode(restricted, label: "Synthetic artwork") == nil)
        }
    }

    private func thumbnailNode(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let result = thumbnailNode(child, label: label, depth: depth + 1) { return result }
        }
        return nil
    }
}
