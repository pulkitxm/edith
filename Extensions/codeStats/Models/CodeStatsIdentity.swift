import EdithExtensionSupport
import CryptoKit
import Foundation

public struct CodeStatsIdentity: Codable, Equatable, Hashable, Sendable {
    public var substrings: [String]
    public var emails: [String]

    public init(substrings: [String] = [], emails: [String] = []) {
        self.substrings = substrings
        self.emails = emails
    }

    public var isEmpty: Bool { substrings.isEmpty && emails.isEmpty }

    public var labels: [String] { emails + substrings.map { "*\($0)*" } }

    public var authorPatterns: [String] {
        (substrings + emails).map(Self.escapeRegex)
    }

    public var fingerprint: String {
        let canonical = [
            substrings.map { $0.lowercased() }.sorted().joined(separator: "\n"),
            emails.map { $0.lowercased() }.sorted().joined(separator: "\n"),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }
            .joined()
    }

    public func matcher() -> @Sendable (String, String) -> Bool {
        let loweredSubstrings = substrings.map { $0.lowercased() }.filter { !$0.isEmpty }
        let loweredEmails = Set(emails.map { $0.lowercased() })
        return { name, email in
            let loweredEmail = email.lowercased()
            if loweredEmails.contains(loweredEmail) { return true }
            let haystack = name.lowercased() + " " + loweredEmail
            return loweredSubstrings.contains { haystack.contains($0) }
        }
    }

    public static func seeded(login: String, emails: [String]) -> CodeStatsIdentity {
        CodeStatsIdentity(substrings: login.isEmpty ? [] : [login], emails: emails)
    }

    private static let regexMetacharacters = Set(".*+?^${}()|[]\\")

    static func escapeRegex(_ value: String) -> String {
        value.reduce(into: "") { escaped, character in
            if regexMetacharacters.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
    }
}
