import Foundation

public struct SEOAuditInputError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum SEOAuditPageEdit: Equatable, Sendable {
    case all
    case none
    case only([String])
    case add([String])
    case remove([String])
}

public struct SEOAuditDraft: Codable, Equatable, Sendable {
    public var discoveredPageURLs: [String]
    public var selectedPageURLs: [String]
    public var includeLighthouse: Bool
    public var activeTaskIDs: [UUID]

    public init(
        discoveredPageURLs: [String] = [], selectedPageURLs: [String] = [],
        includeLighthouse: Bool = true, activeTaskIDs: [UUID] = []
    ) {
        self.discoveredPageURLs = discoveredPageURLs
        self.selectedPageURLs = selectedPageURLs
        self.includeLighthouse = includeLighthouse
        self.activeTaskIDs = activeTaskIDs
    }
}

public struct SEOAuditDraftWrite: Codable, Sendable {
    public let id: UUID
    public let draft: SEOAuditDraft

    public init(id: UUID, draft: SEOAuditDraft) {
        self.id = id
        self.draft = draft
    }
}

public struct SEOAuditSocialCard: Equatable, Sendable {
    public let platform: SEOAuditSocialPlatform
    public let title: String
    public let detail: String
    public let imageURL: String?
    public let snapshotURL: String?
    public let formatLabel: String
    public let usesSummaryCard: Bool

    public init(metadata: SEOAuditMetadata, platform: SEOAuditSocialPlatform) {
        self.platform = platform
        let summary = metadata.twitterCard?.lowercased() == "summary"
        usesSummaryCard = platform == .x && summary
        if platform == .x {
            title =
                metadata.twitterTitle ?? metadata.openGraphTitle ?? metadata.title
                ?? "No social title"
            detail =
                metadata.twitterDescription ?? metadata.openGraphDescription
                ?? metadata.description ?? "No social description"
            imageURL = metadata.twitterImageURL ?? metadata.openGraphImageURL
            snapshotURL =
                metadata.twitterImageSnapshotURL ?? metadata.openGraphImageSnapshotURL
        } else {
            title = metadata.openGraphTitle ?? metadata.title ?? "No social title"
            detail =
                metadata.openGraphDescription ?? metadata.description ?? "No social description"
            imageURL = metadata.openGraphImageURL
            snapshotURL = metadata.openGraphImageSnapshotURL
        }
        formatLabel = usesSummaryCard ? "1:1 · summary" : platform.formatLabel
    }
}

public enum SEOAuditSelection {
    public static func makeProject(url raw: String, name: String?) throws -> SEOAuditProject {
        guard let url = SEOAuditURLInput.normalize(raw) else {
            throw SEOAuditInputError("Enter a valid site URL.")
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved =
            trimmed.isEmpty ? SEOAuditURLInput.projectName(for: url) : trimmed
        return SEOAuditProject(name: resolved, baseURL: url.absoluteString)
    }

    public static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    public static func knownPageURLs(in project: SEOAuditProject) -> [String] {
        var values: [String] = []
        for run in project.runs {
            for page in run.pages { values.append(page.url) }
        }
        return unique(values)
    }

    public static func mergeDiscovery(
        discovered: [String], selected: Set<String>, found: [String]
    ) -> (discovered: [String], selected: [String]) {
        let previous = Set(discovered)
        var nextSelected = selected
        nextSelected.formUnion(Set(found).subtracting(previous))
        let nextDiscovered = unique(discovered + found)
        let chosen = nextDiscovered.filter { nextSelected.contains($0) }
        let extras = nextSelected.subtracting(Set(nextDiscovered)).sorted()
        return (nextDiscovered, chosen + extras)
    }

    public static func choose(
        discovered: [String], selected: [String], edit: SEOAuditPageEdit
    ) throws -> [String] {
        let allowed = Set(discovered)
        func known(_ urls: [String]) throws -> [String] {
            let values = unique(urls)
            let unknown = values.filter { !allowed.contains($0) }
            guard unknown.isEmpty else {
                throw SEOAuditInputError(
                    "These pages are not in the discovery list: \(unknown.joined(separator: ", "))."
                )
            }
            return values
        }
        switch edit {
        case .all:
            return discovered
        case .none:
            return []
        case let .only(urls):
            let values = try known(urls)
            let order = Dictionary(
                uniqueKeysWithValues: discovered.enumerated().map { ($1, $0) })
            return values.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
        case let .add(urls):
            return unique(selected + (try known(urls)))
        case let .remove(urls):
            let drop = Set(urls)
            return selected.filter { !drop.contains($0) }
        }
    }

    public static func auditURLs(discovered: [String], selected: Set<String>) -> [URL] {
        var urls: [URL] = []
        for value in discovered where selected.contains(value) {
            if let url = URL(string: value) { urls.append(url) }
        }
        return urls
    }

    public static func filter(
        _ pages: [SEOAuditPageResult], query: String, severity: SEOAuditSeverity?
    ) -> [SEOAuditPageResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return pages.filter { page in
            let matchesQuery =
                trimmedQuery.isEmpty
                || page.url.localizedCaseInsensitiveContains(trimmedQuery)
                || page.metadata.title?.localizedCaseInsensitiveContains(trimmedQuery) == true
            let matchesSeverity =
                severity == nil || page.issues.contains { $0.severity == severity }
            return matchesQuery && matchesSeverity
        }
    }

    public static func run(in project: SEOAuditProject, id: UUID?, offset: Int) -> SEOAuditRun? {
        let ordered = project.runs.sorted { $0.startedAt > $1.startedAt }
        if let id { return ordered.first { $0.id == id } }
        guard ordered.indices.contains(offset) else { return nil }
        return ordered[offset]
    }
}
