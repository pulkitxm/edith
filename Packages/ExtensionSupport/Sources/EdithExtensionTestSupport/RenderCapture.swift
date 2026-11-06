import AppKit
import EdithExtensionCore
import EdithExtensionUI
import QuartzCore
import SwiftUI

public enum RenderCaptureError: Error, Equatable, CustomStringConvertible {
    case exposedOnDesktop(String)
    case wrongSize(String, CGSize)
    case blank(String)
    case missingBitmap(String)
    case missingPNG(String)

    public var description: String {
        switch self {
        case .exposedOnDesktop(let name): "\(name) reached a visible screen"
        case .wrongSize(let name, let size): "\(name) rendered at \(size)"
        case .blank(let name): "\(name) rendered a single color"
        case .missingBitmap(let name): "\(name) produced no bitmap"
        case .missingPNG(let name): "\(name) could not encode a PNG"
        }
    }
}

@MainActor
public enum RenderCapture {
    public struct Variant: Sendable, Hashable {
        public let name: String
        public let width: Double
        public let height: Double
        public let zoom: Double
        public let scheme: ColorScheme

        public init(name: String, width: Double, height: Double, zoom: Double, scheme: ColorScheme)
        {
            self.name = name
            self.width = width
            self.height = height
            self.zoom = zoom
            self.scheme = scheme
        }

        public var size: CGSize { CGSize(width: width, height: height) }
        public var compact: Bool { width < 720 * zoom }
    }

    public struct Rendered {
        public let bitmap: NSBitmapImageRep
        public let host: NSView
    }

    public static let variants = [
        Variant(name: "regular-light", width: 1100, height: 760, zoom: 1, scheme: .light),
        Variant(name: "regular-dark", width: 1100, height: 760, zoom: 1, scheme: .dark),
        Variant(name: "compact-light", width: 640, height: 700, zoom: 1, scheme: .light),
        Variant(name: "compact-dark", width: 640, height: 700, zoom: 1, scheme: .dark),
        Variant(name: "zoom-light", width: 1100, height: 760, zoom: 1.6, scheme: .light),
        Variant(name: "wide-light", width: 1600, height: 900, zoom: 1, scheme: .light),
    ]

    public static let sheetVariants = [
        Variant(name: "sheet-light", width: 640, height: 560, zoom: 1, scheme: .light),
        Variant(name: "sheet-dark", width: 640, height: 560, zoom: 1, scheme: .dark),
        Variant(name: "zoom-dark", width: 1024, height: 1120, zoom: 1.6, scheme: .dark),
    ]

    public static var directory: URL? {
        ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @TaskLocal private static var holdsScale = false
    private static var scaleHeld = false
    private static var scaleWaiters: [CheckedContinuation<Void, Never>] = []

    public static func exclusiveScale<T>(_ body: @MainActor () async throws -> T) async rethrows
        -> T
    {
        if holdsScale { return try await body() }
        if scaleHeld {
            await withCheckedContinuation { scaleWaiters.append($0) }
        }
        scaleHeld = true
        defer {
            if scaleWaiters.isEmpty {
                scaleHeld = false
            } else {
                scaleWaiters.removeFirst().resume()
            }
        }
        return try await $holdsScale.withValue(true) { try await body() }
    }

    @discardableResult
    public static func render<Content: View>(
        _ name: String, variant: Variant, settle: Duration = .milliseconds(450),
        @ViewBuilder content: () -> Content
    ) async throws -> Rendered {
        try await exclusiveScale {
            try await renderHoldingScale(name, variant: variant, settle: settle, content: content)
        }
    }

    private static func renderHoldingScale<Content: View>(
        _ name: String, variant: Variant, settle: Duration,
        @ViewBuilder content: () -> Content
    ) async throws -> Rendered {
        let label = "\(name)-\(variant.name)"
        let defaults = ExtensionScope.process.defaults()
        let storedZoom = defaults.object(forKey: WindowZoom.defaultsKey)
        let storedScale = UIScale.current
        defaults.set(variant.zoom, forKey: WindowZoom.defaultsKey)
        UIScale.apply(variant.zoom)
        defer {
            UIScale.apply(storedScale)
            if let storedZoom {
                defaults.set(storedZoom, forKey: WindowZoom.defaultsKey)
            } else {
                defaults.removeObject(forKey: WindowZoom.defaultsKey)
            }
        }
        let state = ExtensionPresentationState(
            compact: variant.compact, visible: false, availableWidth: variant.width,
            intrinsic: false)
        let root = state.withContext {
            content()
                .frame(width: variant.width, height: variant.height, alignment: .topLeading)
                .background(DashSkin.paper(variant.scheme == .dark))
                .themedControls()
                .environment(\.compactLayout, variant.compact)
                .environment(\.colorScheme, variant.scheme)
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.loadingAnimationsEnabled, false)
                .environment(\.controlActiveState, .key)
                .transaction { $0.animation = nil }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: variant.size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant.scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            TextEditingCommands.shutdown()
        }
        try await Task.sleep(for: settle)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard !TestWindowHost.isExposedOnDesktop(window) else {
            throw RenderCaptureError.exposedOnDesktop(label)
        }
        guard host.bounds.size == variant.size else {
            throw RenderCaptureError.wrongSize(label, host.bounds.size)
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderCaptureError.missingBitmap(label)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard distinctColors(bitmap) > 1 else { throw RenderCaptureError.blank(label) }
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw RenderCaptureError.missingPNG(label)
            }
            try data.write(to: directory.appendingPathComponent("\(label).png"), options: .atomic)
        }
        return Rendered(bitmap: bitmap, host: host)
    }

    public struct InkBounds: Equatable, Sendable, CustomStringConvertible {
        public let leading: Int
        public let trailing: Int
        public let top: Int

        public var description: String { "x \(leading)...\(trailing) top \(top)" }

        public func matches(_ other: InkBounds, tolerance: Int = 2) -> Bool {
            abs(leading - other.leading) <= tolerance && abs(trailing - other.trailing) <= tolerance
                && abs(top - other.top) <= tolerance
        }
    }

    public static func inkBounds(
        _ bitmap: NSBitmapImageRep, below floor: Int = 0, threshold: Double = 0.008
    ) -> InkBounds? {
        let scale = max(1, bitmap.pixelsWide / max(1, Int(bitmap.size.width)))
        let luminance = { (x: Int, y: Int) -> Double in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return 0
            }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let background = luminance(1, bitmap.pixelsHigh - 2)
        var leading = Int.max
        var trailing = Int.min
        var top = Int.max
        for y in stride(from: floor * scale, to: bitmap.pixelsHigh, by: scale) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: scale)
            where abs(luminance(x, y) - background) > threshold {
                leading = min(leading, x / scale)
                trailing = max(trailing, x / scale)
                top = min(top, y / scale)
            }
        }
        guard top != .max else { return nil }
        return InkBounds(leading: leading, trailing: trailing, top: top)
    }

    public static func distinctColors(_ bitmap: NSBitmapImageRep) -> Int {
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

    public static func withAccessibility<T>(_ body: () async throws -> T) async rethrows -> T {
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
        return try await body()
    }

    public static func find(_ node: NSObject, label: String, depth: Int = 0) -> NSObject? {
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
