import EdithExtensionSupport
import Foundation

public struct HostWorkerConfiguration: Codable, Sendable {
    public let identifier: String
    public let supportDirectory: URL
    public let extensionID: String
    public let version: String
    public let theme: String
    public let appearance: String
    public let zoom: Double
    public var recoveryOnly: Bool = false

    public init(identity: HostIdentity, extensionID: String, version: String) {
        identifier = identity.identifier
        supportDirectory =
            identity.development
            ? identity.root.deletingLastPathComponent().deletingLastPathComponent()
            : identity.root.deletingLastPathComponent()
        self.extensionID = extensionID
        self.version = version
        let preferences = SharedDefaults.applicationStore(identifier: identity.identifier)
        theme = preferences?.string(forKey: AppStorageKeys.General.theme) ?? "accent"
        appearance = preferences?.string(forKey: AppStorageKeys.General.appearance) ?? "system"
        let storedZoom = preferences?.double(forKey: AppStorageKeys.General.mainWindowZoom) ?? 1
        zoom = storedZoom.isFinite && storedZoom > 0 ? min(1.6, max(0.8, storedZoom)) : 1
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

public struct HostWorkerProcessGroup: Codable, Sendable {
    public let kind: String
    public let pid: Int32
    public let registered: Bool
    public let generation: String

    public init(pid: Int32, generation: String, registered: Bool) {
        kind = "processGroup"
        self.pid = pid
        self.registered = registered
        self.generation = generation
    }
}

public enum HostWorkerError: Error, Equatable {
    case exited
    case timedOut
    case invalidResponse
    case rejected
    case stillRunning
    case disableRejected(String)
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

public extension HostWorkerError {
    var disableMessage: String {
        if case .disableRejected(let message) = self { return message }
        return
            "Cleanup is pending. Restore system settings or finish macOS approval, then try again."
    }
}
