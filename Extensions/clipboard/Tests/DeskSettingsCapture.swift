import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
enum DeskSettingsCapture {
    struct Variant {
        let name: String
        let width: Double
        let height: Double
        let zoom: Double
        let scheme: ColorScheme
    }

    static let variants: [Variant] = [
        .init(name: "sheet-light", width: 640, height: 560, zoom: 1, scheme: .light),
        .init(name: "sheet-dark", width: 640, height: 560, zoom: 1, scheme: .dark),
        .init(name: "regular-light", width: 1100, height: 760, zoom: 1, scheme: .light),
        .init(name: "regular-dark", width: 1100, height: 760, zoom: 1, scheme: .dark),
        .init(name: "compact-light", width: 640, height: 700, zoom: 1, scheme: .light),
        .init(name: "zoom-dark", width: 1024, height: 1120, zoom: 1.6, scheme: .dark),
    ]

    static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static func render<Content: View>(
        _ name: String, variant: Variant, settle: Duration = .milliseconds(240),
        @ViewBuilder content: () -> Content
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
            compact: variant.width < 720 * variant.zoom, visible: true,
            availableWidth: variant.width, intrinsic: false)
        let root = state.withContext { content().pageSurface() }
        let appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root.environment(\.colorScheme, variant.scheme))
        host.sizingOptions = []
        host.appearance = appearance
        let frame = CGRect(x: 0, y: 0, width: variant.width, height: variant.height)
        host.frame = frame
        let window = DeskOffscreenWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.appearance = appearance
        window.setFrameOrigin(DeskOffscreenWindow.origin(for: frame.size))
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let deadline = ContinuousClock.now + settle
        repeat {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        let bitmap = try requireBitmap(host)
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("\(name)-\(variant.name).png"))
            }
        }
        return bitmap
    }

    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var colors: Set<UInt32> = []
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(
                        UInt32(color.redComponent * 255) << 16
                            | UInt32(color.greenComponent * 255) << 8
                            | UInt32(color.blueComponent * 255))
                }
            }
        }
        return colors.count
    }

    private static func requireBitmap(_ host: NSView) throws -> NSBitmapImageRep {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.featureUnsupported)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
}

final class DeskOffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    static func origin(for size: NSSize) -> NSPoint {
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        return NSPoint(x: minX - size.width - 1_000, y: minY - size.height - 1_000)
    }
}
