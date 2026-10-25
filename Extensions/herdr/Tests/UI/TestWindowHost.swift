import AppKit
import Foundation

@MainActor
enum TestWindowHost {
    static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        return application
    }()

    static func window(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask = [.borderless]
    ) -> OffscreenTestWindow {
        _ = application
        let window = OffscreenTestWindow(
            contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.setFrameOrigin(offscreenOrigin(for: contentRect.size))
        return window
    }

    static func isExposedOnDesktop(_ window: NSWindow) -> Bool {
        window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    static var exposedWindows: [NSWindow] {
        NSApp?.windows.filter(isExposedOnDesktop) ?? []
    }

    private static func offscreenOrigin(for size: NSSize) -> NSPoint {
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        return NSPoint(x: minX - size.width - 1_000, y: minY - size.height - 1_000)
    }
}

final class OffscreenTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor final class HerdrAccessibilityFixture {
    struct Access {
        let copy: (String) throws -> CFTypeRef?
        let set: (String, CFTypeRef?) throws -> Void

        init(
            copy: @escaping (String) throws -> CFTypeRef?,
            set: @escaping (String, CFTypeRef?) throws -> Void
        ) {
            self.copy = copy
            self.set = set
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case mismatch(operation: String, attribute: String)
        case notSettable(attribute: String)

        var description: String {
            switch self {
            case .notSettable(let attribute):
                return "Accessibility activation attribute is not settable: \(attribute)"
            case .mismatch(let operation, let attribute):
                return "Accessibility \(operation) readback differs for \(attribute)"
            }
        }
    }

    struct ActivationFailure: Error, CustomStringConvertible {
        let primary: any Error
        let restoration: [any Error]

        var description: String {
            ([String(describing: primary)] + restoration.map { String(describing: $0) })
                .joined(separator: "; ")
        }
    }

    private let access: Access
    private var pending: [(attribute: String, value: CFTypeRef?)] = []

    init(attributes: [String], access: Access) throws {
        self.access = access
        let originals = try attributes.map { (attribute: $0, value: try access.copy($0)) }
        do {
            for original in originals {
                pending.append(original)
                try access.set(original.attribute, kCFBooleanTrue)
                guard Self.equal(try access.copy(original.attribute), kCFBooleanTrue) else {
                    throw Failure.mismatch(operation: "enable", attribute: original.attribute)
                }
            }
        } catch {
            throw ActivationFailure(primary: error, restoration: restore())
        }
    }

    private static func equal(_ left: CFTypeRef?, _ right: CFTypeRef?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case (let left?, let right?): return CFEqual(left, right)
        default: return false
        }
    }

    func restore() -> [any Error] {
        var failures: [any Error] = []
        var remaining: [(attribute: String, value: CFTypeRef?)] = []
        for original in pending.reversed() {
            do {
                try access.set(original.attribute, original.value)
                guard Self.equal(try access.copy(original.attribute), original.value) else {
                    throw Failure.mismatch(operation: "restore", attribute: original.attribute)
                }
            } catch {
                failures.append(error)
                remaining.insert(original, at: 0)
            }
        }
        pending = remaining
        return failures
    }
}

extension HerdrAccessibilityFixture {
    static func enable() throws -> HerdrAccessibilityFixture {
        let application: NSApplication = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard application.accessibilityIsAttributeSettable(attribute) else {
            throw Failure.notSettable(attribute: attribute.rawValue)
        }
        return try HerdrAccessibilityFixture(
            attributes: [attribute.rawValue],
            access: Access(
                copy: { attribute in
                    application.accessibilityAttributeValue(
                        NSAccessibility.Attribute(rawValue: attribute)) as AnyObject?
                },
                set: { attribute, value in
                    application.accessibilitySetValue(
                        value, forAttribute: NSAccessibility.Attribute(rawValue: attribute))
                }))
    }
}
