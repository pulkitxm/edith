import Foundation

public struct HostWorkerConfiguration: Codable, Sendable {
    public let identifier: String
    public let supportDirectory: URL
    public let extensionID: String
    public let version: String

    public init(identity: HostIdentity, extensionID: String, version: String) {
        identifier = identity.identifier
        supportDirectory =
            identity.development
            ? identity.root.deletingLastPathComponent().deletingLastPathComponent()
            : identity.root.deletingLastPathComponent()
        self.extensionID = extensionID
        self.version = version
    }

    public func identity() throws -> HostIdentity {
        try HostIdentity(identifier: identifier, supportDirectory: supportDirectory)
    }
}

public struct HostWorkerRequest: Codable, Sendable {
    public let token: UUID
    public let operation: String
    public let configuration: HostWorkerConfiguration?

    public init(operation: String, configuration: HostWorkerConfiguration? = nil) {
        token = UUID()
        self.operation = operation
        self.configuration = configuration
    }
}

public struct HostWorkerResponse: Codable, Sendable {
    public let token: UUID
    public let ok: Bool
    public let version: String?
    public let message: String?

    public init(token: UUID, ok: Bool, version: String? = nil, message: String? = nil) {
        self.token = token
        self.ok = ok
        self.version = version
        self.message = message
    }
}

public enum HostWorkerError: Error, Equatable {
    case exited
    case timedOut
    case invalidResponse
    case rejected
    case stillRunning
}

public struct HostWorkerFrames: Sendable {
    public static let maximumBytes = 65_536
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if byte == 10 {
                guard !buffer.isEmpty else { throw HostWorkerError.invalidResponse }
                frames.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < Self.maximumBytes else {
                    throw HostWorkerError.invalidResponse
                }
                buffer.append(byte)
            }
        }
        return frames
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw HostWorkerError.invalidResponse }
        data.append(10)
        return data
    }
}
