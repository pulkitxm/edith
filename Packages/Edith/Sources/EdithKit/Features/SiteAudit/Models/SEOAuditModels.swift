import Foundation

public enum SEOAuditSeverity: String, Codable, CaseIterable, Sendable {
    case error
    case warning
    case notice
}

public struct SEOAuditIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(severity.rawValue):\(code)" }
    public let code: String
    public let severity: SEOAuditSeverity
    public let title: String
    public let detail: String

    public init(code: String, severity: SEOAuditSeverity, title: String, detail: String) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct SEOAuditScores: Codable, Equatable, Sendable {
    public let performance: Int?
    public let accessibility: Int?
    public let bestPractices: Int?
    public let seo: Int?

    public init(performance: Int?, accessibility: Int?, bestPractices: Int?, seo: Int?) {
        self.performance = performance
        self.accessibility = accessibility
        self.bestPractices = bestPractices
        self.seo = seo
    }

    public static let unavailable = SEOAuditScores(
        performance: nil, accessibility: nil, bestPractices: nil, seo: nil)

    public var values: [Int] {
        [performance, accessibility, bestPractices, seo].compactMap { $0 }
    }

    public var average: Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
}

public struct SEOAuditMetadata: Codable, Equatable, Sendable {
    public let title: String?
    public let description: String?
    public let canonicalURL: String?
    public let robots: String?
    public let language: String?
    public let heading: String?
    public let openGraphTitle: String?
    public let openGraphDescription: String?
    public let openGraphImageURL: String?
    public let openGraphImageSnapshotURL: String?
    public let openGraphType: String?
    public let twitterCard: String?
    public let twitterTitle: String?
    public let twitterDescription: String?
    public let twitterImageURL: String?
    public let twitterImageSnapshotURL: String?
    public let wordCount: Int

    public init(
        title: String?, description: String?, canonicalURL: String?, robots: String?,
        language: String?, heading: String?, openGraphTitle: String?,
        openGraphDescription: String?, openGraphImageURL: String?,
        openGraphImageSnapshotURL: String?, openGraphType: String?, twitterCard: String?,
        twitterTitle: String?, twitterDescription: String?, twitterImageURL: String?,
        twitterImageSnapshotURL: String?, wordCount: Int
    ) {
        self.title = title
        self.description = description
        self.canonicalURL = canonicalURL
        self.robots = robots
        self.language = language
        self.heading = heading
        self.openGraphTitle = openGraphTitle
        self.openGraphDescription = openGraphDescription
        self.openGraphImageURL = openGraphImageURL
        self.openGraphImageSnapshotURL = openGraphImageSnapshotURL
        self.openGraphType = openGraphType
        self.twitterCard = twitterCard
        self.twitterTitle = twitterTitle
        self.twitterDescription = twitterDescription
        self.twitterImageURL = twitterImageURL
        self.twitterImageSnapshotURL = twitterImageSnapshotURL
        self.wordCount = wordCount
    }

    public func withImageSnapshots(_ snapshots: SEOAuditImageSnapshots) -> SEOAuditMetadata {
        SEOAuditMetadata(
            title: title, description: description, canonicalURL: canonicalURL, robots: robots,
            language: language, heading: heading, openGraphTitle: openGraphTitle,
            openGraphDescription: openGraphDescription, openGraphImageURL: openGraphImageURL,
            openGraphImageSnapshotURL: snapshots.openGraphImageURL,
            openGraphType: openGraphType, twitterCard: twitterCard, twitterTitle: twitterTitle,
            twitterDescription: twitterDescription, twitterImageURL: twitterImageURL,
            twitterImageSnapshotURL: snapshots.twitterImageURL, wordCount: wordCount)
    }
}

public struct SEOAuditImageSnapshots: Equatable, Sendable {
    public let openGraphImageURL: String?
    public let twitterImageURL: String?

    public init(openGraphImageURL: String?, twitterImageURL: String?) {
        self.openGraphImageURL = openGraphImageURL
        self.twitterImageURL = twitterImageURL
    }
}

public enum SEOAuditSocialPlatform: String, CaseIterable, Identifiable, Sendable {
    case facebook
    case x
    case linkedIn
    case slack
    case discord

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .facebook: "Facebook"
        case .x: "X"
        case .linkedIn: "LinkedIn"
        case .slack: "Slack"
        case .discord: "Discord"
        }
    }

    public var icon: String {
        switch self {
        case .facebook: "person.2.fill"
        case .x: "bubble.left.and.bubble.right.fill"
        case .linkedIn: "briefcase.fill"
        case .slack: "number"
        case .discord: "person.3.fill"
        }
    }

    public var formatLabel: String {
        switch self {
        case .facebook: "1.91:1 · 1200×630"
        case .x: "2:1 · large card"
        case .linkedIn: "1.91:1 · 1200×627"
        case .slack: "1.91:1 · unfurl"
        case .discord: "1.91:1 · embed"
        }
    }
}

public struct SEOAuditPageResult: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let url: String
    public let auditedAt: Date
    public let statusCode: Int?
    public let responseMilliseconds: Int?
    public let bytes: Int
    public let metadata: SEOAuditMetadata
    public let scores: SEOAuditScores
    public let issues: [SEOAuditIssue]
    public let error: String?

    public init(
        id: UUID = UUID(), url: String, auditedAt: Date = Date(), statusCode: Int?,
        responseMilliseconds: Int?, bytes: Int, metadata: SEOAuditMetadata,
        scores: SEOAuditScores = .unavailable, issues: [SEOAuditIssue], error: String? = nil
    ) {
        self.id = id
        self.url = url
        self.auditedAt = auditedAt
        self.statusCode = statusCode
        self.responseMilliseconds = responseMilliseconds
        self.bytes = bytes
        self.metadata = metadata
        self.scores = scores
        self.issues = issues
        self.error = error
    }

    public var errorCount: Int { issues.count { $0.severity == .error } }
    public var warningCount: Int { issues.count { $0.severity == .warning } }
    public var hasLighthouseScores: Bool { !scores.values.isEmpty }

    public func with(metadata: SEOAuditMetadata) -> SEOAuditPageResult {
        SEOAuditPageResult(
            id: id, url: url, auditedAt: auditedAt, statusCode: statusCode,
            responseMilliseconds: responseMilliseconds, bytes: bytes, metadata: metadata,
            scores: scores, issues: issues, error: error)
    }

    public func with(scores: SEOAuditScores, lighthouseError: String?) -> SEOAuditPageResult {
        var updatedIssues = issues.filter { $0.code != "lighthouse-unavailable" }
        if let lighthouseError {
            updatedIssues.append(
                SEOAuditIssue(
                    code: "lighthouse-unavailable", severity: .notice,
                    title: "Lighthouse did not finish", detail: lighthouseError))
        }
        return SEOAuditPageResult(
            id: id, url: url, auditedAt: auditedAt, statusCode: statusCode,
            responseMilliseconds: responseMilliseconds, bytes: bytes, metadata: metadata,
            scores: scores, issues: updatedIssues, error: error)
    }
}

public enum SEOAuditRunState: String, Codable, Sendable {
    case running
    case completed
    case cancelled
    case failed
}

public struct SEOAuditRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: SEOAuditRunState
    public var discoveredPageCount: Int
    public var pages: [SEOAuditPageResult]
    public var error: String?

    public init(
        id: UUID = UUID(), startedAt: Date = Date(), finishedAt: Date? = nil,
        state: SEOAuditRunState = .running, discoveredPageCount: Int = 0,
        pages: [SEOAuditPageResult] = [], error: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.state = state
        self.discoveredPageCount = discoveredPageCount
        self.pages = pages
        self.error = error
    }

    public var progress: Double {
        guard discoveredPageCount > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(pages.count) / Double(discoveredPageCount))
    }

    public var issueCount: Int { pages.reduce(0) { $0 + $1.issues.count } }
    public var averageScore: Int? {
        let scores = pages.compactMap(\.scores.average)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }
}

public struct SEOAuditProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: String
    public var createdAt: Date
    public var updatedAt: Date
    public var imageURL: String?
    public var imageSnapshotURL: String?
    public var runs: [SEOAuditRun]

    public init(
        id: UUID = UUID(), name: String, baseURL: String, createdAt: Date = Date(),
        updatedAt: Date = Date(), imageURL: String? = nil, imageSnapshotURL: String? = nil,
        runs: [SEOAuditRun] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.imageURL = imageURL
        self.imageSnapshotURL = imageSnapshotURL
        self.runs = runs
    }

    public var latestRun: SEOAuditRun? { runs.max { $0.startedAt < $1.startedAt } }

    public func history(for url: String, excluding runID: UUID) -> [SEOAuditPageResult] {
        runs.filter { $0.id != runID }.compactMap { run in
            run.pages.first { $0.url == url }
        }.sorted { $0.auditedAt > $1.auditedAt }
    }
}

public struct SEOAuditProjectSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let baseURL: String
    public let updatedAt: Date
    public let imageURL: String?
    public let imageSnapshotURL: String?
    public let latestRun: SEOAuditRunSummary?

    public init(project: SEOAuditProject) {
        id = project.id
        name = project.name
        baseURL = project.baseURL
        updatedAt = project.updatedAt
        imageURL = project.imageURL
        imageSnapshotURL = project.imageSnapshotURL
        latestRun = project.latestRun.map(SEOAuditRunSummary.init)
    }
}

public struct SEOAuditRunSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let state: SEOAuditRunState
    public let pageCount: Int
    public let issueCount: Int
    public let averageScore: Int?

    public init(run: SEOAuditRun) {
        id = run.id
        startedAt = run.startedAt
        state = run.state
        pageCount = run.pages.count
        issueCount = run.issueCount
        averageScore = run.averageScore
    }
}

public enum SEOAuditStage: Equatable, Sendable {
    case idle
    case discovering
    case auditing(current: Int, total: Int, url: String)
    case lighthouse(url: String)
    case saving
}

public struct SEOAuditURLInput {
    public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()) {
            return url
        }
        let scheme =
            trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1")
            ? "http" : "https"
        return URL(string: "\(scheme)://\(trimmed)")
    }

    public static func projectName(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        if host == "localhost", let port = url.port { return "localhost:\(port)" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
