import EdithExtensionSupport
import Foundation

@objc public protocol HostRemoteControl {
    func exchange(_ data: Data, reply: @escaping (Data) -> Void)
}

@objc public protocol HostRemoteEvents {
    func receive(_ data: Data)
}

public struct HostExtensionContentRequest: Codable, Equatable, Sendable {
    public let extensionID: String
    public let location: String
    public let section: String?
    public let presentationID: UUID
    public let surface: SurfaceSnapshotRequest?

    public init(
        extensionID: String, location: String, section: String? = nil,
        presentationID: UUID = UUID(), surface: SurfaceSnapshotRequest? = nil
    ) {
        self.extensionID = extensionID
        self.location = location
        self.section = section
        self.presentationID = presentationID
        self.surface = surface
    }

    public func validate(extensionID: String) throws {
        guard self.extensionID == extensionID,
            [
                "main", "settings", "home", "notch", "sidebar.utility", "music.footer",
                "music.sidebar", "music.detail",
            ].contains(location),
            section.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true
        else { throw HostWorkerError.rejected }
        if let surface {
            guard location == surface.target.rawValue else { throw HostWorkerError.rejected }
            _ = try surface.encoded(providerID: extensionID)
        }
    }
}

public struct HostRemotePresentation: Codable, Equatable, Sendable {
    public let session: UUID
    public let request: HostExtensionContentRequest
    public let compact: Bool
    public let visible: Bool
    public let availableWidth: Double

    public init(
        session: UUID, request: HostExtensionContentRequest, compact: Bool,
        visible: Bool, availableWidth: Double
    ) {
        self.session = session
        self.request = request
        self.compact = compact
        self.visible = visible
        self.availableWidth = availableWidth
    }

    public func validate(session: UUID, extensionID: String) throws {
        guard self.session == session, availableWidth.isFinite,
            (0...16_384).contains(availableWidth)
        else { throw HostWorkerError.rejected }
        try request.validate(extensionID: extensionID)
    }
}

public struct HostRemoteSceneRequest: Codable, Sendable {
    public let token: UUID
    public let operation: String
    public let presentation: HostRemotePresentation

    public init(operation: String, presentation: HostRemotePresentation) {
        token = UUID()
        self.operation = operation
        self.presentation = presentation
    }
}

public struct HostRemoteEvent: Codable, Sendable {
    public let kind: String
    public let presentationID: UUID?
    public let height: Double?

    public init(kind: String, presentationID: UUID? = nil, height: Double? = nil) {
        self.kind = kind
        self.presentationID = presentationID
        self.height = height
    }
}

public enum HostRemoteWire {
    public static let maximumBytes = 131_072

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try JSONEncoder().encode(value)
        guard !bytes.isEmpty, bytes.count <= maximumBytes else {
            throw HostWorkerError.invalidResponse
        }
        return bytes
    }

    public static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else {
            throw HostWorkerError.invalidResponse
        }
        return try JSONDecoder().decode(type, from: bytes)
    }
}
