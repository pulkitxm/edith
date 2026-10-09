@_implementationOnly import EdithExtensionSupport
import AppKit
import Foundation

struct AttentionServiceError: LocalizedError, Equatable, Sendable {
    enum Kind: String { case refused, unavailable, failed }
    let message: String
    init(_ message: String) { self.message = message }
    init(_ kind: Kind, _ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AttentionPayload {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

enum AttentionPeer {
    static func invoke(_ command: String, payload: Data = Data(), timeout: TimeInterval = 30)
        async throws -> Data
    {
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "attention") else {
            throw ExtensionPeerError.unavailable
        }
        return try await endpoint.invoke(command, payload: payload, timeout: timeout)
    }
}

enum AttentionCloudStorage {
    static var directory: URL {
        if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil {
            return AttentionPaths.root.appendingPathComponent("fixture-cloud", isDirectory: true)
        }
        if let path = ProcessInfo.processInfo.environment["EDITH_ATTENTION_CLOUD_ROOT"],
            path.hasPrefix("/")
        {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Edith/Attention", isDirectory: true)
    }
    static var available: Bool {
        guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil else {
            return false
        }
        return FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path)
    }
}

struct AttentionObservedAgent: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case working, blocked, idle, finished, error }
    var id: String
    var kind: String
    var machineName: String
    var cwd: String
    var title: String
    var status: Status
    var isTerminal: Bool
}
struct AttentionAgentHost: Codable, Equatable, Sendable {
    var reachable: Bool
    var agents: [AttentionObservedAgent]
}

enum AttentionMediaNotifications {
    static var state: String { namespace + ".musicState" }
    static var request: String { namespace + ".requestMusicState" }
    private static var namespace: String {
        ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"]
            ?? "edith.attention.testing"
    }
    static func observe(_ name: String, _ action: @escaping ([AnyHashable: Any]) -> Void)
        -> NSObjectProtocol
    {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { action($0.userInfo ?? [:]) }
    }
    static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }
    static func stopObserving(_ observer: NSObjectProtocol?) {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
