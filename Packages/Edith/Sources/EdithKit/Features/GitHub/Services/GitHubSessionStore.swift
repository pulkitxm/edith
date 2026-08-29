import EdithCore
import Foundation

public actor GitHubSessionStore {
    public static let shared = GitHubSessionStore()

    public let file: URL

    public init(
        file: URL = AppData.supportDir.appendingPathComponent("github")
            .appendingPathComponent("browser-session.json")
    ) {
        self.file = file
    }

    public func restore() throws -> GitHubBrowserSession {
        guard FileManager.default.fileExists(atPath: file.path) else { return Self.homeSession() }
        let session = try JSONDecoder().decode(
            GitHubBrowserSession.self, from: Data(contentsOf: file))
        return session.tabs.isEmpty ? Self.homeSession() : session
    }

    public func save(_ session: GitHubBrowserSession) throws {
        let value = session.tabs.isEmpty ? Self.homeSession() : session
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    public nonisolated static func homeSession() -> GitHubBrowserSession {
        let entry = GitHubBrowserHistoryEntry(
            route: GitHubRoute(host: .github, resource: .home))
        let tab = GitHubBrowserTab(entry: entry, title: "GitHub")
        return GitHubBrowserSession(tabs: [tab], selectedTabID: tab.id)
    }
}
