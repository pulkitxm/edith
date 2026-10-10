import EdithExtensionSupport
import Foundation

public struct UsageStatusLineStatusResponse: Codable, Equatable, Sendable {
    public let installed: Bool
    public let recordedAt: Date?
}

public struct UsageStatusLineChangeResponse: Codable, Equatable, Sendable {
    public let change: String
}

public actor UsageStatusLineCommands {
    public static let maximumRequestBytes = 512 * 1_024
    public static let maximumResponseBytes = 16 * 1_024
    private let settings: URL
    private let history: URL
    private let executable: String?
    private let connection: UsageStatusLineConnection
    private var stopping = false
    private var operations: [UUID: Task<Data, Error>] = [:]

    var activeOperationCount: Int { operations.count }

    public init(
        settings: URL = ClaudeStatusLine.settingsURL(), history: URL = LimitsHistory.url,
        executable: String? = nil,
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.settings = settings
        self.history = history
        self.executable = executable
        connection = UsageStatusLineConnection(
            settings: settings,
            marker: history.deletingLastPathComponent().appendingPathComponent(
                "claude-statusline-connection.json"),
            executable: executable, defaults: defaults)
    }

    public func suspendOwnedHook() async throws {
        let connection = self.connection
        try await Task.detached(priority: .utility) { try connection.suspendOwnedHook() }.value
    }

    public func shutdown() async throws {
        stopping = true
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        for operation in pending { _ = await operation.result }
        try await suspendOwnedHook()
    }

    public func resumeOwnedHook() async throws {
        guard !stopping else { throw ExtensionPeerError.unavailable }
        let connection = self.connection
        let operation = Task.detached(priority: .utility) { try connection.resumeOwnedHook() }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    public func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !stopping, operations.count < 8 else { throw ExtensionPeerError.unavailable }
        guard payload.count <= Self.maximumRequestBytes,
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let settings = self.settings
        let history = self.history
        let executable = self.executable
        let connection = self.connection
        let operation = Task.detached(priority: .utility) { () throws -> Data in
            try Task.checkCancellation()
            let result: Data
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            switch command {
            case "usage.statusline.hook":
                guard
                    Set(object.keys).isDisjoint(with: [
                        "input", "settings", "executable", "command", "then",
                    ])
                else { throw ExtensionPeerError.invalidRequest }
                let limits = ClaudeStatusLine.record(payload, history: history)
                result = try encoder.encode(limits.map(ClaudeStatusLine.line) ?? "")
                if limits != nil { UsageEvents.post(UsageEvents.limitsUpdated) }
            case "usage.statusline.status":
                guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
                result = try encoder.encode(
                    UsageStatusLineStatusResponse(
                        installed: ClaudeStatusLine.isInstalled(settings: settings),
                        recordedAt: LimitsHistory.latest(provider: .claude, url: history)?.date))
            case "usage.statusline.install":
                guard object.isEmpty, executable != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
                let change = try connection.connect()
                result = try encoder.encode(UsageStatusLineChangeResponse(change: change.rawValue))
            case "usage.statusline.remove":
                guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
                let change = try connection.disconnect()
                result = try encoder.encode(UsageStatusLineChangeResponse(change: change.rawValue))
            default: throw ExtensionPeerError.invalidRequest
            }
            try Task.checkCancellation()
            guard result.count <= Self.maximumResponseBytes else {
                throw ExtensionPeerError.invalidRequest
            }
            return result
        }
        let identifier = UUID()
        operations[identifier] = operation
        defer { operations.removeValue(forKey: identifier) }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
}
