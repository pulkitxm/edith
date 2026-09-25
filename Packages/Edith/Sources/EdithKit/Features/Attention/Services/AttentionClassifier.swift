import Foundation

public struct AttentionJevDecision: Codable, Equatable, Sendable {
    public static let none = "none"

    public var categoryID: String
    public var confidence: Double
    public var decidedAt: Date

    public init(categoryID: String, confidence: Double, decidedAt: Date = Date()) {
        self.categoryID = categoryID
        self.confidence = confidence
        self.decidedAt = decidedAt
    }

    public var isDecisive: Bool { categoryID != Self.none }
}

public struct AttentionClassifications: Codable, Equatable, Sendable {
    public var entities: [String: AttentionJevDecision]
    public var titles: [String: AttentionJevDecision]

    public init(
        entities: [String: AttentionJevDecision] = [:],
        titles: [String: AttentionJevDecision] = [:]
    ) {
        self.entities = entities
        self.titles = titles
    }

    public static func titleKey(entityID: String, title: String) -> String {
        entityID + "\u{1F}" + AttentionText.normalizedTitle(title)
    }
}

public struct AttentionClassification: Equatable, Sendable {
    public var entityID: String
    public var entityName: String
    public var categoryID: String
    public var source: AttentionCategorySource
    public var confidence: Double?
    public var domain: String?
}

public enum AttentionText {
    public static func domain(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let host = URL(string: raw)?.host ?? raw
        var value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if value.hasPrefix("www.") { value.removeFirst(4) }
        return value.isEmpty ? nil : value
    }

    public static func location(_ raw: String?) -> String? {
        guard let raw, let components = URLComponents(string: raw), let host = components.host
        else { return nil }
        var value = host.lowercased()
        if value.hasPrefix("www.") { value.removeFirst(4) }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        return value + path.lowercased()
    }

    public static func pattern(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value.removeFirst(scheme.count)
        }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public static func project(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.isEmpty || name == "/" || name == "~" ? nil : name
    }

    public static func normalizedTitle(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("("), let close = value.firstIndex(of: ")"),
            value[value.index(after: value.startIndex)..<close].allSatisfy(\.isNumber)
        {
            value = String(value[value.index(after: close)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return String(value.lowercased().prefix(200))
    }
}

public struct AttentionClassifier {
    private struct Candidate {
        var rule: AttentionIdentityRule
        var isUser: Bool
        var isIdentity: Bool
    }

    private let settings: AttentionSettings
    private let classifications: AttentionClassifications
    private let specific: [Candidate]
    private let broad: [Candidate]
    private var cache: [String: AttentionClassification] = [:]

    public init(
        settings: AttentionSettings, classifications: AttentionClassifications = .init(),
        catalog: [AttentionIdentityRule] = AttentionCatalog.rules
    ) {
        self.settings = settings
        self.classifications = classifications
        let user = settings.rules.filter { !$0.isEmpty }.map {
            Candidate(rule: $0, isUser: true, isIdentity: $0.isIdentity)
        }
        let builtIn = catalog.map {
            Candidate(
                rule: $0, isUser: false,
                isIdentity: $0.isIdentity && AttentionCatalog.identityRuleIDs.contains($0.id))
        }
        let ordered = user + builtIn
        specific = ordered.enumerated().filter { $0.element.rule.specificity > 1 }
            .sorted {
                if $0.element.isUser != $1.element.isUser { return $0.element.isUser }
                if $0.element.rule.specificity != $1.element.rule.specificity {
                    return $0.element.rule.specificity > $1.element.rule.specificity
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
        broad = ordered.filter { $0.rule.specificity == 1 }
    }

    public mutating func classify(_ event: AttentionEvent) -> AttentionClassification {
        let key = [
            event.source.rawValue, event.bundleID ?? event.appName ?? "", event.domain ?? "",
            event.url ?? "", event.windowTitle ?? "",
            (event.tags ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                .joined(separator: ","),
        ].joined(separator: "\u{1F}")
        if let cached = cache[key] { return cached }
        let resolved = resolve(event)
        cache[key] = resolved
        return resolved
    }

    public func entityKey(for event: AttentionEvent) -> String {
        if event.source == .browser, let domain = AttentionText.domain(event.domain ?? event.url) {
            return "web:\(domain)"
        }
        return "app:\(event.bundleID ?? event.appName ?? "unknown")"
    }

    private func resolve(_ event: AttentionEvent) -> AttentionClassification {
        let bundleID = event.bundleID?.lowercased()
        let domain = AttentionText.domain(event.domain ?? event.url)
        let location = AttentionText.location(event.url)
        let title = event.windowTitle?.lowercased() ?? ""
        let tags = event.tags ?? [:]
        let fallbackID = entityKey(for: event)
        let fallbackName: String =
            if event.source == .browser, let domain { domain } else {
                event.appName ?? event.bundleID ?? "Unknown application"
            }

        var identity: (candidate: Candidate, score: Int)?
        var broadMatch: (candidate: Candidate, score: Int)?
        for candidate in broad {
            let score = targetScore(candidate.rule, bundleID: bundleID, domain: domain)
            guard score > 0 else { continue }
            if broadMatch == nil || score > broadMatch!.score
                || (score == broadMatch!.score && candidate.isUser && !broadMatch!.candidate.isUser)
            {
                broadMatch = (candidate, score)
            }
            if candidate.isIdentity,
                identity == nil || score > identity!.score
                    || (score == identity!.score && candidate.isUser
                        && !identity!.candidate.isUser)
            {
                identity = (candidate, score)
            }
        }
        let entityID: String
        let entityName: String
        if let identity {
            entityID =
                identity.candidate.isUser
                ? "identity:\(identity.candidate.rule.id)" : "catalog:\(identity.candidate.rule.id)"
            entityName = identity.candidate.rule.name
        } else {
            entityID = fallbackID
            entityName = fallbackName
        }

        func result(_ category: String, _ source: AttentionCategorySource, _ confidence: Double?)
            -> AttentionClassification
        {
            AttentionClassification(
                entityID: entityID, entityName: entityName, categoryID: category, source: source,
                confidence: confidence, domain: domain)
        }

        for candidate in specific
        where matches(
            candidate.rule, bundleID: bundleID, domain: domain, location: location, title: title,
            tags: tags)
        {
            return result(candidate.rule.categoryID, candidate.isUser ? .user : .catalog, nil)
        }
        if let windowTitle = event.windowTitle, !windowTitle.isEmpty,
            let decision = classifications.titles[
                AttentionClassifications.titleKey(entityID: fallbackID, title: windowTitle)],
            decision.isDecisive
        {
            return result(decision.categoryID, .jev, decision.confidence)
        }
        if let broadMatch {
            return result(
                broadMatch.candidate.rule.categoryID,
                broadMatch.candidate.isUser ? .user : .catalog, nil)
        }
        if let decision = classifications.entities[fallbackID], decision.isDecisive {
            return result(decision.categoryID, .jev, decision.confidence)
        }
        return result(AttentionCatalog.unclassified, .none, nil)
    }

    private func targetScore(
        _ rule: AttentionIdentityRule, bundleID: String?, domain: String?
    ) -> Int {
        if let bundleID, rule.bundleIDs.contains(where: { $0.lowercased() == bundleID }) {
            return 10_000
        }
        guard let domain else { return 0 }
        var best = 0
        for raw in rule.domains {
            let candidate = AttentionText.pattern(raw)
            guard !candidate.isEmpty else { continue }
            if domain == candidate || domain.hasSuffix("." + candidate) {
                best = max(best, candidate.count)
            }
        }
        return best
    }

    private func matches(
        _ rule: AttentionIdentityRule, bundleID: String?, domain: String?, location: String?,
        title: String, tags: [String: String]
    ) -> Bool {
        if !rule.bundleIDs.isEmpty || !rule.domains.isEmpty {
            guard targetScore(rule, bundleID: bundleID, domain: domain) > 0 else { return false }
        }
        if !rule.urls.isEmpty {
            guard let location,
                rule.urls.contains(where: {
                    let pattern = AttentionText.pattern($0)
                    return !pattern.isEmpty && location.hasPrefix(pattern)
                })
            else { return false }
        }
        if !rule.keywords.isEmpty {
            guard
                rule.keywords.contains(where: {
                    let keyword = $0.trimmingCharacters(in: .whitespaces).lowercased()
                    return !keyword.isEmpty && title.contains(keyword)
                })
            else { return false }
        }
        for context in rule.contexts {
            let parts = context.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard let key = parts.first, !key.isEmpty else { continue }
            guard let value = tags.first(where: { $0.key.lowercased() == key })?.value else {
                return false
            }
            if parts.count == 2, value.lowercased() != parts[1] { return false }
        }
        return true
    }
}
