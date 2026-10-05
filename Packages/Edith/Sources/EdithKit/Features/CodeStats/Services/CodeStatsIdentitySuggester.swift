import Foundation

public enum CodeStatsIdentitySuggester {
    public static let limit = 10
    static let minimumReferenceLength = 3
    static let variantMinimumLength = 4
    static let variantMaximumDifference = 3
    static let noreplyDomain = "users.noreply.github.com"
    static let hostnameSuffixes = [".local", ".lan", ".localdomain", ".home", ".internal"]

    public static func suggestions(
        authors: [CodeStatsAuthor], identity: CodeStatsIdentity, login: String?,
        name: String?, agents: [String] = [], limit: Int = limit
    ) -> [CodeStatsIdentitySuggestion] {
        let references = references(identity: identity, login: login, name: name)
        guard !references.isEmpty else { return [] }
        let attribution = CodeStatsAttribution(identity: identity, agents: agents, owned: false)
        let counted = identity.matcher()
        var merged: [String: CodeStatsIdentitySuggestion] = [:]
        for author in authors where !author.email.isEmpty {
            guard !counted(author.name, author.email),
                !attribution.isAgent(name: author.name, email: author.email),
                !attribution.isAutomation(name: author.name, email: author.email),
                let matched = match(author, references: references)
            else { continue }
            let (reason, score) = matched
            let key = author.email.lowercased()
            if var existing = merged[key] {
                existing.commits += author.commits
                if score > existing.score {
                    existing.score = score
                    existing.reason = reason
                    existing.name = author.name
                }
                merged[key] = existing
            } else {
                merged[key] = CodeStatsIdentitySuggestion(
                    name: author.name, email: author.email, commits: author.commits,
                    value: author.email, reason: reason, score: score)
            }
        }
        return merged.values.sorted {
            ($0.score, $0.commits, $1.value) > ($1.score, $1.commits, $0.value)
        }.prefix(limit).map { $0 }
    }

    public static func filtered(
        _ suggestions: [CodeStatsIdentitySuggestion], identity: CodeStatsIdentity
    ) -> [CodeStatsIdentitySuggestion] {
        let counted = identity.matcher()
        return suggestions.filter { !counted($0.name, $0.email) }
    }

    static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    static func references(identity: CodeStatsIdentity, login: String?, name: String?) -> Set<
        String
    > {
        var values = identity.substrings + identity.emails.map(localPart)
        if let login { values.append(login) }
        if let name {
            values.append(name)
            values += name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        }
        return Set(values.map(normalize).filter { $0.count >= minimumReferenceLength })
    }

    static func localPart(_ email: String) -> String {
        let local = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? email
        guard let plus = local.firstIndex(of: "+") else { return local }
        let prefix = local[..<plus]
        return prefix.allSatisfy(\.isNumber) ? String(local[local.index(after: plus)...]) : local
    }

    static func isHostname(_ domain: String) -> Bool {
        domain.isEmpty || domain == "(none)" || !domain.contains(".")
            || hostnameSuffixes.contains { domain.hasSuffix($0) }
    }

    private static func match(
        _ author: CodeStatsAuthor, references: Set<String>
    ) -> (CodeStatsSuggestionReason, Int)? {
        let email = author.email.lowercased()
        let domain = email.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init)
            ?? ""
        let local = normalize(localPart(email))
        if domain == noreplyDomain, references.contains(local) { return (.noreply, 100) }
        let candidates = Set([normalize(author.name), local].filter { !$0.isEmpty })
        let hostname = isHostname(domain)
        if !candidates.isDisjoint(with: references) {
            return hostname ? (.hostname, 90) : (.sameName, 80)
        }
        let variant = candidates.contains { candidate in
            references.contains { reference in
                let shorter = candidate.count <= reference.count ? candidate : reference
                let longer = shorter == candidate ? reference : candidate
                return shorter.count >= variantMinimumLength
                    && longer.count - shorter.count <= variantMaximumDifference
                    && longer.hasPrefix(shorter)
            }
        }
        guard variant else { return nil }
        return hostname ? (.hostname, 70) : (.variant, 60)
    }
}
