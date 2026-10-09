import Foundation

public struct VirtualCameraExtensionStatus: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public var version: Int
    public var build: String
    public var clients: [String]
    public var format: VirtualCameraFormat
    public var receivingFrames: Bool

    public init(
        version: Int = VirtualCameraExtensionStatus.protocolVersion, build: String,
        clients: [String], format: VirtualCameraFormat, receivingFrames: Bool
    ) {
        self.version = version
        self.build = build
        self.clients = clients
        self.format = format
        self.receivingFrames = receivingFrames
    }

    public var isInUse: Bool { !clients.isEmpty }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> VirtualCameraExtensionStatus? {
        try? JSONDecoder().decode(VirtualCameraExtensionStatus.self, from: Data(text.utf8))
    }
}

public enum VirtualCameraProperty {
    public static let statusSelector = "edst"
    public static let globalScope = "glob"
    public static let mainElement = "0000"

    public static var statusKey: String {
        key(selector: statusSelector, scope: globalScope, element: mainElement)
    }

    public static var statusCode: UInt32 { fourCharCode(statusSelector) }

    public static func key(selector: String, scope: String, element: String) -> String {
        "4cc_\(selector)_\(scope)_\(element)"
    }

    public static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
