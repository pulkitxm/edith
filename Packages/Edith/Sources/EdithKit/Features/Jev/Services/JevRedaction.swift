import Foundation

public enum JevRedaction {
    public static let placeholder = "[redacted]"
    public static let defaultLimit = 3_000

    private static let rules: [(NSRegularExpression, String)] = [
        (
            #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#,
            placeholder
        ),
        (#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 " + placeholder),
        (
            #"(?i)\b(password|passwd|token|secret|api[_-]?key)(["']?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"',;]+)"#,
            "$1$2" + placeholder
        ),
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, placeholder),
        (#"\bgh[pousr]_[A-Za-z0-9]{8,}"#, placeholder),
        (#"\bgithub_pat_[A-Za-z0-9_]{8,}"#, placeholder),
        (#"\bAKIA[0-9A-Z]{12,}"#, placeholder),
        (#"\bxox[abeoprs]-[A-Za-z0-9-]{8,}"#, placeholder),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    public static func redact(_ text: String) -> String {
        rules.reduce(text) { value, rule in
            rule.0.stringByReplacingMatches(
                in: value, range: NSRange(value.startIndex..., in: value), withTemplate: rule.1)
        }
    }

    public static func tail(_ text: String, limit: Int = defaultLimit) -> String {
        let redacted = redact(text)
        guard redacted.count > limit else { return redacted }
        return String(redacted.suffix(limit))
    }
}
