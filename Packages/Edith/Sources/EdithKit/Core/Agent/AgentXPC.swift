import Foundation

@objc public protocol EdithAgentXPC {
    func handshake(peerVersion: Int, reply: @escaping (Data?, String?) -> Void)
    func snapshot(topic: String, reply: @escaping (Data?, String?) -> Void)
    func subscribe(topic: String, reply: @escaping (String?) -> Void)
    func unsubscribe(topic: String, reply: @escaping (String?) -> Void)
    func perform(operation: String, payload: Data, reply: @escaping (Data?, String?) -> Void)
}

@objc public protocol EdithAgentSubscriberXPC {
    func topicChanged(topic: String, payload: Data)
}

public enum AgentPeerIdentity {
    public static let identifiers = [
        "com.pulkit.edith",
        "com.pulkit.edith.helper.v2",
        "com.pulkit.edith.agent",
        "ed",
    ]

    public static func requirement(teamIdentifier: String?) -> String {
        let identity = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        guard let teamIdentifier, !teamIdentifier.isEmpty else {
            return "(\(identity))"
        }
        return "(\(identity)) and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public struct AgentRuntimeSnapshot: Codable, Equatable, Sendable {
    public let build: String
    public let startedAt: Date
    public let processIdentifier: Int32
    public let residentBytes: UInt64
    public let cpuPercent: Double
    public let subscriberCount: Int
    public let storePath: String
    public let schemaVersion: Int

    public init(
        build: String, startedAt: Date, processIdentifier: Int32, residentBytes: UInt64,
        cpuPercent: Double, subscriberCount: Int, storePath: String, schemaVersion: Int
    ) {
        self.build = build
        self.startedAt = startedAt
        self.processIdentifier = processIdentifier
        self.residentBytes = residentBytes
        self.cpuPercent = cpuPercent
        self.subscriberCount = subscriberCount
        self.storePath = storePath
        self.schemaVersion = schemaVersion
    }

    public var uptime: TimeInterval { Date().timeIntervalSince(startedAt) }
}

public enum AgentPayload {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
