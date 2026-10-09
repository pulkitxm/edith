import EdithExtensionSupport
import CryptoKit
import Foundation

public struct CodeStatsAttribution: Sendable {
    public static let defaultAgents = [
        "claude[bot]", "@anthropic.com", "cursor agent", "cursoragent@cursor.com", "copilot",
        "+copilot@users.noreply.github.com", "codex", "@openai.com",
        "chatgpt-codex-connector[bot]", "devin-ai-integration[bot]", "pukbot[bot]",
        "+pukbot[bot]@users.noreply.github.com",
    ]

    public static let automation = [
        "dependabot", "renovate", "github-actions", "release-please", "semantic-release",
        "greenkeeper", "snyk-bot", "mergify", "imgbot", "allcontributors", "depfu",
        "pre-commit-ci", "web-flow",
    ]

    public let identity: CodeStatsIdentity
    public let agents: [String]
    public let owned: Bool
    private let isMine: @Sendable (String, String) -> Bool

    public init(identity: CodeStatsIdentity, agents: [String] = [], owned: Bool) {
        self.identity = identity
        self.agents = Array(
            Set((Self.defaultAgents + agents).map { $0.lowercased() }.filter { !$0.isEmpty })
        ).sorted()
        self.owned = owned
        isMine = identity.matcher()
    }

    public var authorPatterns: [String] {
        identity.authorPatterns
            + (owned ? agents.map(CodeStatsIdentity.escapeRegex) : [])
    }

    public static func isPrimary(
        _ authors: [CodeStatsAuthor], identity: CodeStatsIdentity
    ) -> Bool {
        let attribution = CodeStatsAttribution(identity: identity, owned: false)
        let matcher = identity.matcher()
        var mine = 0
        var others: [String: Int] = [:]
        for author in authors
        where !attribution.isAgent(name: author.name, email: author.email)
            && !attribution.isAutomation(name: author.name, email: author.email)
        {
            if matcher(author.name, author.email) {
                mine += author.commits
            } else {
                others[author.email.lowercased(), default: 0] += author.commits
            }
        }
        return mine > 0 && mine >= (others.values.max() ?? 0)
    }

    public static func isOwned(
        _ repository: String, logins: Set<String>
    ) -> Bool {
        let owner = repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return logins.contains(owner.lowercased())
    }

    public var fingerprint: String {
        let canonical = [
            "rules \(CodeStatsLanguage.rulesVersion)", identity.fingerprint,
            agents.joined(separator: "\n"), owned ? "owned" : "foreign",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }
            .joined()
    }

    public func isAgent(name: String, email: String) -> Bool {
        let name = name.lowercased()
        let email = email.lowercased()
        return agents.contains { $0.contains("@") ? email.contains($0) : name == $0 }
    }

    public func isAutomation(name: String, email: String) -> Bool {
        let haystack = name.lowercased() + " " + email.lowercased()
        if Self.automation.contains(where: haystack.contains) { return true }
        return name.lowercased().hasSuffix("[bot]") && !isAgent(name: name, email: email)
    }

    public func flags(name: String, email: String, coAuthors: [String]) -> CodeStatsCommitFlags? {
        if isMine(name, email) { return [] }
        let coAuthored = coAuthors.contains { trailer in
            let parsed = Self.parseTrailer(trailer)
            return isMine(parsed.name, parsed.email)
        }
        if isAgent(name: name, email: email) {
            return owned || coAuthored ? .agentAssisted : nil
        }
        if isAutomation(name: name, email: email) { return nil }
        return coAuthored ? .coAuthored : nil
    }

    public static func parseTrailer(_ value: String) -> (name: String, email: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"),
            open < close
        else { return (trimmed, trimmed.contains("@") ? trimmed : "") }
        return (
            String(trimmed[..<open]).trimmingCharacters(in: .whitespaces),
            String(trimmed[trimmed.index(after: open)..<close])
        )
    }
}
