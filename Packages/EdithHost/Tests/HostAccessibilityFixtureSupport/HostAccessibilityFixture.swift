import AppKit
import Foundation

@MainActor public final class HostAccessibilityFixture {
    public struct Access {
        let copy: (String) throws -> CFTypeRef?
        let set: (String, CFTypeRef?) throws -> Void

        public init(
            copy: @escaping (String) throws -> CFTypeRef?,
            set: @escaping (String, CFTypeRef?) throws -> Void
        ) {
            self.copy = copy
            self.set = set
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case mismatch(operation: String, attribute: String)
        case notSettable(attribute: String)

        public var description: String {
            switch self {
            case .notSettable(let attribute):
                return "Accessibility activation attribute is not settable: \(attribute)"
            case .mismatch(let operation, let attribute):
                return "Accessibility \(operation) readback differs for \(attribute)"
            }
        }
    }

    public struct ActivationFailure: Error, CustomStringConvertible {
        public let primary: any Error
        public let restoration: [any Error]

        public var description: String {
            ([String(describing: primary)] + restoration.map { String(describing: $0) })
                .joined(separator: "; ")
        }
    }

    private let access: Access
    private var pending: [(attribute: String, value: CFTypeRef?)] = []

    public static func enable() throws -> HostAccessibilityFixture {
        let application: NSApplication = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard application.accessibilityIsAttributeSettable(attribute) else {
            throw Failure.notSettable(attribute: attribute.rawValue)
        }
        return try HostAccessibilityFixture(
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

    public init(attributes: [String], access: Access) throws {
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

    public func restore() -> [any Error] {
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
