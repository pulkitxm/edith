import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import QuartzCore
import SwiftUI
import Testing

@MainActor
enum SurfaceCapture {
    struct Variant {
        let name: String
        let size: CGSize
        let scheme: ColorScheme
        let zoom: Double

        var compact: Bool { size.width < 720 }
    }

    static let variants: [Variant] = [
        .init(
            name: "regular-light", size: CGSize(width: 1100, height: 760), scheme: .light, zoom: 1),
        .init(name: "regular-dark", size: CGSize(width: 1100, height: 760), scheme: .dark, zoom: 1),
        .init(
            name: "compact-light", size: CGSize(width: 640, height: 700), scheme: .light, zoom: 1),
        .init(name: "compact-dark", size: CGSize(width: 640, height: 700), scheme: .dark, zoom: 1),
        .init(
            name: "zoom-light", size: CGSize(width: 1100, height: 760), scheme: .light, zoom: 1.6),
    ]

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @discardableResult
    static func render<Content: View>(
        _ name: String, variant: Variant, @ViewBuilder content: () -> Content
    ) async throws -> NSBitmapImageRep {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let defaults = ExtensionScope.process.defaults()
        let storedZoom = defaults.object(forKey: WindowZoom.defaultsKey)
        let storedScale = UIScale.current
        defaults.set(variant.zoom, forKey: WindowZoom.defaultsKey)
        UIScale.apply(variant.zoom)
        defer {
            if let storedZoom {
                defaults.set(storedZoom, forKey: WindowZoom.defaultsKey)
            } else {
                defaults.removeObject(forKey: WindowZoom.defaultsKey)
            }
            UIScale.apply(storedScale)
        }
        let state = ExtensionPresentationState(
            compact: variant.compact, visible: false, availableWidth: variant.size.width,
            intrinsic: false)
        let root = state.withContext {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DashSkin.paper(variant.scheme == .dark))
                .environment(\.colorScheme, variant.scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .transaction { $0.animation = nil }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        host.appearance = appearance
        host.frame = CGRect(origin: .zero, size: variant.size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.appearance = appearance
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(
            NSPoint(x: minX - variant.size.width - 1_000, y: minY - variant.size.height - 1_000))
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<12 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.needsDisplay = true
            host.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!window.isVisible)
        #expect(host.bounds.size == variant.size)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(distinctColors(bitmap) > 4)
        let corner = bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)
        let brightness = corner.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }
        #expect(variant.scheme == .dark ? (brightness ?? 1) < 0.35 : (brightness ?? 0) > 0.65)
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(name)-\(variant.name).png"))
        }
        return bitmap
    }

    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors: Set<UInt32> = []
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                colors.insert(
                    UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8
                        | UInt32(color.blueComponent * 255))
            }
        }
        return colors.count
    }
}
