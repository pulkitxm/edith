import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor
enum CodeStatsRenderCapture {
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

    @discardableResult
    static func render<Content: View>(
        _ name: String, variant: Variant, settle: Duration = .milliseconds(300),
        @ViewBuilder content: () -> Content
    ) async throws -> NSBitmapImageRep {
        let previousAppearance = application.appearance
        application.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        let previous = UIScale.current
        UIScale.apply(variant.zoom)
        defer {
            UIScale.apply(previous)
            application.appearance = previousAppearance
        }
        let frame = NSRect(x: 0, y: 0, width: variant.width, height: variant.height)
        let host = NSHostingView(
            rootView: content()
                .frame(width: variant.width, height: variant.height)
                .environment(\.compactLayout, variant.width < UIScale.pt(720))
                .environment(\.colorScheme, variant.scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.controlActiveState, .key)
                .transaction { $0.animation = nil })
        host.frame = frame
        let window = NSWindow(
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
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        let deadline = ContinuousClock.now + settle
        repeat {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
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
        return bitmap
    }

    static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let key =
                    Int(color.redComponent * 15) << 8 | Int(color.greenComponent * 15) << 4
                    | Int(color.blueComponent * 15)
                seen.insert(key)
            }
        }
        return seen.count
    }
}
