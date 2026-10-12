import ApplicationServices
import Foundation

@MainActor public final class HostAccessibilityFixture {
    public struct Access {
        let copy: (String) throws -> CFTypeRef
        let set: (String, CFTypeRef) throws -> Void

        public init(
            copy: @escaping (String) throws -> CFTypeRef,
            set: @escaping (String, CFTypeRef) throws -> Void
        ) {
            self.copy = copy
            self.set = set
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case api(operation: String, attribute: String, status: Int32)
        case missingValue(attribute: String)
        case mismatch(operation: String, attribute: String)

        public var description: String {
            switch self {
            case .api(let operation, let attribute, let status):
                return "Accessibility \(operation) failed for \(attribute): AXError \(status)"
            case .missingValue(let attribute):
                return "Accessibility snapshot has no value for \(attribute)"
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

    public static let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"]

    private let access: Access
    private var pending: [(attribute: String, value: CFTypeRef)] = []

    public static func enable() throws -> HostAccessibilityFixture {
        let application = AXUIElementCreateApplication(getpid())
        return try HostAccessibilityFixture(
            access: Access(
                copy: { attribute in
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(
                        application, attribute as CFString, &value)
                    guard status == .success else {
                        throw Failure.api(
                            operation: "copy", attribute: attribute, status: status.rawValue)
                    }
                    guard let value else { throw Failure.missingValue(attribute: attribute) }
                    return value
                },
                set: { attribute, value in
                    let status = AXUIElementSetAttributeValue(
                        application, attribute as CFString, value)
                    guard status == .success else {
                        throw Failure.api(
                            operation: "set", attribute: attribute, status: status.rawValue)
                    }
                }))
    }

    public init(access: Access) throws {
        self.access = access
        let originals = try Self.attributes.map { (attribute: $0, value: try access.copy($0)) }
        do {
            for original in originals {
                pending.append(original)
                try access.set(original.attribute, kCFBooleanTrue)
                guard CFEqual(try access.copy(original.attribute), kCFBooleanTrue) else {
                    throw Failure.mismatch(operation: "enable", attribute: original.attribute)
                }
            }
        } catch {
            throw ActivationFailure(primary: error, restoration: restore())
        }
    }

    public func restore() -> [any Error] {
        var failures: [any Error] = []
        var remaining: [(attribute: String, value: CFTypeRef)] = []
        for original in pending.reversed() {
            do {
                try access.set(original.attribute, original.value)
                guard CFEqual(try access.copy(original.attribute), original.value) else {
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
