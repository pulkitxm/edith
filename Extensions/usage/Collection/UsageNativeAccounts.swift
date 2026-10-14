import EdithExtensionAccounts
import Foundation

public struct UsageNativeAccounts: Sendable {
    var sessions: [String: UUID]
    var names: [UUID: String]

    public init() { self.init(sessions: [:], names: [:]) }

    init(sessions: [String: UUID], names: [UUID: String]) {
        self.sessions = sessions
        self.names = names
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Self {
        guard let directory = try? ClaudeAccountStorage.directory(environment: environment),
            let sessions = try? ClaudeAccountSessions.accounts(directory: directory),
            !sessions.isEmpty
        else { return .init() }
        let accounts = (try? await ClaudeAccountStorage(directory: directory).load().accounts) ?? []
        return .init(
            sessions: sessions,
            names: Dictionary(
                accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
    }

    func source(of event: UsageNativeEvent) -> String {
        guard event.source == "cli", let account = sessions[event.session] else {
            return event.source
        }
        return "account:" + account.uuidString.lowercased() + ":cli"
    }

    func label(_ source: String) -> String? {
        let parts = source.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "account", parts[2] == "cli",
            let account = UUID(uuidString: String(parts[1]))
        else { return nil }
        return "Claude Code · " + (names[account] ?? "Removed account")
    }
}
