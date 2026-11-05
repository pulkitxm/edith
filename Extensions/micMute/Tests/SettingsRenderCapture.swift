import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor
enum SettingsRenderCapture {
    struct Variant {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let zoom: Double
        let scheme: ColorScheme
    }

    static let variants = [
        Variant(name: "regular-light", width: 1100, height: 760, zoom: 1, scheme: .light),
        Variant(name: "regular-dark", width: 1100, height: 760, zoom: 1, scheme: .dark),
        Variant(name: "compact-light", width: 640, height: 700, zoom: 1, scheme: .light),
        Variant(name: "compact-dark", width: 640, height: 700, zoom: 1, scheme: .dark),
        Variant(name: "zoomed", width: 1100, height: 760, zoom: 1.6, scheme: .light),
    ]

    static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        return application
    }()

    static func render<Content: View>(
        _ name: String, variant: Variant, @ViewBuilder content: () -> Content
    ) async throws -> NSView {
        _ = application
        let defaults = SharedDefaults.store
        let priorZoom = defaults.object(forKey: WindowZoom.defaultsKey)
        let previous = UIScale.current
        defaults.set(variant.zoom, forKey: WindowZoom.defaultsKey)
        UIScale.apply(variant.zoom)
        defer {
            UIScale.apply(previous)
            if let priorZoom {
                defaults.set(priorZoom, forKey: WindowZoom.defaultsKey)
            } else {
                defaults.removeObject(forKey: WindowZoom.defaultsKey)
            }
        }
        let frame = NSRect(x: 0, y: 0, width: variant.width, height: variant.height)
        let host = NSHostingView(
            rootView: content()
                .frame(width: variant.width, height: variant.height, alignment: .topLeading)
                .background(DashSkin.paper(variant.scheme == .dark))
                .environment(\.compactLayout, variant.width < UIScale.pt(720))
                .environment(\.colorScheme, variant.scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.controlActiveState, .key)
                .transaction { $0.animation = nil })
        host.frame = frame
        let window = SettingsCaptureWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(
            NSPoint(x: minX - variant.width - 1_000, y: minY - variant.height - 1_000))
        window.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<14 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(abs(host.bounds.width - variant.width) < 1)
        #expect(
            !(window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: directory.appendingPathComponent("\(name)-\(variant.name).png"),
                options: .atomic)
        }
        return host
    }

    static func withAccessibility<T>(_ body: () async throws -> T) async rethrows -> T {
        _ = application
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

    static func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 64 else { return nil }
        if (node as AnyObject).accessibilityLabel?() == label { return node }
        let selector = NSSelectorFromString("accessibilityValue")
        if node.responds(to: selector),
            node.perform(selector)?.takeUnretainedValue() as? String == label
        {
            return node
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [NSObject] ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        for child in (node as? NSView)?.subviews ?? [] {
            if let found = find(child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }
}

private final class SettingsCaptureWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
