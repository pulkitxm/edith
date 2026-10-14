import EdithExtensionAccounts
import Foundation

public struct UsageNativeAccounts: Sendable {
    var sessions: [String: UUID]
    var names: [UUID: String]
    var defaultID: UUID?

    public init() { self.init(sessions: [:], names: [:]) }

    init(sessions: [String: UUID], names: [UUID: String], defaultID: UUID? = nil) {
        self.sessions = sessions
        self.names = names
        self.defaultID = defaultID
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Self {
        guard let directory = try? ClaudeAccountStorage.directory(environment: environment) else {
            return .init()
        }
        let sessions = (try? ClaudeAccountSessions.accounts(directory: directory)) ?? [:]
        let state = (try? await ClaudeAccountStorage(directory: directory).load()) ?? .init()
        return .init(
            sessions: sessions,
            names: Dictionary(
                state.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            defaultID: state.defaultID)
    }

    func source(of event: UsageNativeEvent) -> String {
        guard event.source == "cli", let account = sessions[event.session] else {
            return event.source
        }
        return "account:" + account.uuidString.lowercased() + ":cli"
    }

    func label(_ source: String) -> String? {
        if source == "cli" {
            return defaultID.flatMap { names[$0] }.map { "Claude Code · " + $0 }
        }
        let parts = source.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "account", parts[2] == "cli",
            let account = UUID(uuidString: String(parts[1]))
        else { return nil }
        return "Claude Code · " + (names[account] ?? "Removed account")
    }
}
