import EdithExtensionTestSupport
import AppKit
import CoreGraphics
import CoreImage
import EdithExtensionCore
import SwiftUI
import Testing
@testable import EdithExtensionUI

@MainActor @Suite(.serialized) struct SurfacePresenterCoverRenderingTests {
    private let snapshot = SurfaceSnapshot(
        providerID: "codeStats",
        metrics: [.init("lines", "Lines changed", "1,284")],
        rows: [
            .init(
                "repository", sourceID: "synthetic", title: "Synthetic repository",
                detail: "Synthetic branch", value: "42 commits", icon: .code)
        ],
        actions: [.init("open", "Open Code stats", .arrowUpRight)])

    private func card(presenting: Bool, scheme: ColorScheme) -> some View {
        SurfaceSnapshotContent(
            tile: SurfaceTile(.codeStats), snapshot: snapshot, presenting: presenting,
            perform: { _ in }
        )
        .padding(16).frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &values, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return values
    }

    private func edgeEnergy(_ values: [UInt8], width: Int) -> Int {
        stride(from: 4, to: values.count, by: 4).reduce(0) { total, index in
            guard index % (width * 4) != 0 else { return total }
            return total + abs(Int(values[index]) - Int(values[index - 4]))
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func presentingKeepsTheRealCardLayoutAndAppliesTheBlurOverlay(_ scheme: ColorScheme)
        async throws
    {
        let visible = ImageRenderer(content: card(presenting: false, scheme: scheme))
        let covered = ImageRenderer(content: card(presenting: true, scheme: scheme))
        visible.scale = 2; covered.scale = 2
        let plain = try #require(visible.cgImage)
        let blurred = try #require(covered.cgImage)
        #expect(plain.width == blurred.width && plain.height == blurred.height)
        let plainPixels = try pixels(plain)
        let blurredPixels = try pixels(blurred)
        #expect(plainPixels != blurredPixels)
        #expect(
            edgeEnergy(blurredPixels, width: blurred.width) * 3
                < edgeEnergy(plainPixels, width: plain.width))

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
        var sizes: [CGSize] = []
        for presenting in [false, true] {
            let host = NSHostingView(rootView: card(presenting: presenting, scheme: scheme))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host; window.orderBack(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            sizes.append(host.fittingSize)
            #expect(label(host, "Synthetic repository"))
            #expect(label(host, "1,284"))
            #expect(!label(host, "Hidden while presenting"))
        }
        #expect(sizes[0] == sizes[1])
    }

    @Test func layerCoverMatchesTheSwiftUICoverAndKeepsTheLayerVisible() throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.wantsLayer = true
        let content = CALayer()
        content.frame = view.bounds
        content.contents = NSImage(size: NSSize(width: 8, height: 8))
        try #require(view.layer).addSublayer(content)
        for dark in [true, false] {
            PresenterLayerCover.apply(true, to: content, in: view, dark: dark)
            #expect(!content.isHidden && content.contents != nil)
            #expect(view.layerUsesCoreImageFilters)
            #expect(PresenterLayerCover.covers(content))
            let blur = try #require((content.filters as? [CIFilter])?.first)
            #expect(blur.value(forKey: kCIInputRadiusKey) as? Double == UIScale.pt(28))
            let dim = try #require(
                content.sublayers?.first { $0.name == PresenterLayerCover.dimName })
            #expect(dim.opacity == 0.45 && dim.frame == content.bounds)
            #expect(
                dim.backgroundColor == (dark ? NSColor.black : NSColor.white).cgColor)
            #expect(content.sublayers?.count == 1)
        }
        PresenterLayerCover.apply(false, to: content, in: view)
        #expect(!PresenterLayerCover.covers(content))
        #expect(content.filters == nil && (content.sublayers ?? []).isEmpty)
    }

    private func label(_ node: NSObject, _ text: String, depth: Int = 0) -> Bool {
        guard depth < 64 else { return false }
        if (node as AnyObject).accessibilityLabel?() == text { return true }
        let value = NSSelectorFromString("accessibilityValue")
        if node.responds(to: value), node.perform(value)?.takeUnretainedValue() as? String == text {
            return true
        }
        return ((node as AnyObject).accessibilityChildren?() as? [NSObject] ?? []).contains {
            label($0, text, depth: depth + 1)
        }
    }
}
