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
    private let defaults: UserDefaults

    public init(
        settings: URL = ClaudeStatusLine.settingsURL(), history: URL = LimitsHistory.url,
        executable: String? = ClaudeStatusLine.defaultExecutable(),
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.settings = settings
        self.history = history
        self.executable = executable
        self.defaults = defaults
    }

    public func execute(_ command: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        guard payload.count <= Self.maximumRequestBytes,
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let settings = self.settings
        let history = self.history
        let executable = self.executable
        let defaults = self.defaults
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
                guard object.isEmpty, let executable else {
                    throw ExtensionPeerError.invalidRequest
                }
                let change = try ClaudeStatusLine.connect(
                    executable: executable, settings: settings, defaults: defaults)
                result = try encoder.encode(UsageStatusLineChangeResponse(change: change.rawValue))
            case "usage.statusline.remove":
                guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
                let change = try ClaudeStatusLine.disconnect(settings: settings, defaults: defaults)
                result = try encoder.encode(UsageStatusLineChangeResponse(change: change.rawValue))
            default: throw ExtensionPeerError.invalidRequest
            }
            try Task.checkCancellation()
            guard result.count <= Self.maximumResponseBytes else {
                throw ExtensionPeerError.invalidRequest
            }
            return result
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }
}
