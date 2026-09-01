import Foundation

enum SEOAuditSeverity: String, Codable, CaseIterable, Sendable {
    case error
    case warning
    case notice
}

struct SEOAuditIssue: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(severity.rawValue):\(code)" }
    let code: String
    let severity: SEOAuditSeverity
    let title: String
    let detail: String
}

struct SEOAuditScores: Codable, Equatable, Sendable {
    let performance: Int?
    let accessibility: Int?
    let bestPractices: Int?
    let seo: Int?

    static let unavailable = SEOAuditScores(
        performance: nil, accessibility: nil, bestPractices: nil, seo: nil)

    var values: [Int] {
        [performance, accessibility, bestPractices, seo].compactMap { $0 }
    }

    var average: Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }
}

struct SEOAuditMetadata: Codable, Equatable, Sendable {
    let title: String?
    let description: String?
    let canonicalURL: String?
    let robots: String?
    let language: String?
    let heading: String?
    let openGraphTitle: String?
    let openGraphDescription: String?
    let openGraphImageURL: String?
    let openGraphImageSnapshotURL: String?
    let openGraphType: String?
    let twitterCard: String?
    let twitterTitle: String?
    let twitterDescription: String?
    let twitterImageURL: String?
    let twitterImageSnapshotURL: String?
    let wordCount: Int

    func withImageSnapshots(_ snapshots: SEOAuditImageSnapshots) -> SEOAuditMetadata {
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

struct SEOAuditImageSnapshots: Equatable, Sendable {
    let openGraphImageURL: String?
    let twitterImageURL: String?
}

enum SEOAuditSocialPlatform: String, CaseIterable, Identifiable, Sendable {
    case facebook
    case x
    case linkedIn
    case slack
    case discord

    var id: String { rawValue }

    var title: String {
        switch self {
        case .facebook: "Facebook"
        case .x: "X"
        case .linkedIn: "LinkedIn"
        case .slack: "Slack"
        case .discord: "Discord"
        }
    }

    var icon: String {
        switch self {
        case .facebook: "person.2.fill"
        case .x: "bubble.left.and.bubble.right.fill"
        case .linkedIn: "briefcase.fill"
        case .slack: "number"
        case .discord: "person.3.fill"
        }
    }

    var formatLabel: String {
        switch self {
        case .facebook: "1.91:1 · 1200×630"
        case .x: "2:1 · large card"
        case .linkedIn: "1.91:1 · 1200×627"
        case .slack: "1.91:1 · unfurl"
        case .discord: "1.91:1 · embed"
        }
    }
}

struct SEOAuditPageResult: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let url: String
    let auditedAt: Date
    let statusCode: Int?
    let responseMilliseconds: Int?
    let bytes: Int
    let metadata: SEOAuditMetadata
    let scores: SEOAuditScores
    let issues: [SEOAuditIssue]
    let error: String?

    init(
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

    var errorCount: Int { issues.count { $0.severity == .error } }
    var warningCount: Int { issues.count { $0.severity == .warning } }
    var hasLighthouseScores: Bool { !scores.values.isEmpty }

    func with(metadata: SEOAuditMetadata) -> SEOAuditPageResult {
        SEOAuditPageResult(
            id: id, url: url, auditedAt: auditedAt, statusCode: statusCode,
            responseMilliseconds: responseMilliseconds, bytes: bytes, metadata: metadata,
            scores: scores, issues: issues, error: error)
    }

    func with(scores: SEOAuditScores, lighthouseError: String?) -> SEOAuditPageResult {
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

enum SEOAuditRunState: String, Codable, Sendable {
    case running
    case completed
    case cancelled
    case failed
}

struct SEOAuditRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var finishedAt: Date?
    var state: SEOAuditRunState
    var discoveredPageCount: Int
    var pages: [SEOAuditPageResult]
    var error: String?

    init(
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

    var progress: Double {
        guard discoveredPageCount > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(pages.count) / Double(discoveredPageCount))
    }

    var issueCount: Int { pages.reduce(0) { $0 + $1.issues.count } }
    var averageScore: Int? {
        let scores = pages.compactMap(\.scores.average)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / scores.count
    }
}

struct SEOAuditProject: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var baseURL: String
    var createdAt: Date
    var updatedAt: Date
    var imageURL: String?
    var imageSnapshotURL: String?
    var runs: [SEOAuditRun]

    init(
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

    var latestRun: SEOAuditRun? { runs.max { $0.startedAt < $1.startedAt } }

    func history(for url: String, excluding runID: UUID) -> [SEOAuditPageResult] {
        runs.filter { $0.id != runID }.compactMap { run in
            run.pages.first { $0.url == url }
        }.sorted { $0.auditedAt > $1.auditedAt }
    }
}

struct SEOAuditProjectSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let baseURL: String
    let updatedAt: Date
    let imageURL: String?
    let imageSnapshotURL: String?
    let latestRun: SEOAuditRunSummary?

    init(project: SEOAuditProject) {
        id = project.id
        name = project.name
        baseURL = project.baseURL
        updatedAt = project.updatedAt
        imageURL = project.imageURL
        imageSnapshotURL = project.imageSnapshotURL
        latestRun = project.latestRun.map(SEOAuditRunSummary.init)
    }
}

struct SEOAuditRunSummary: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let state: SEOAuditRunState
    let pageCount: Int
    let issueCount: Int
    let averageScore: Int?

    init(run: SEOAuditRun) {
        id = run.id
        startedAt = run.startedAt
        state = run.state
        pageCount = run.pages.count
        issueCount = run.issueCount
        averageScore = run.averageScore
    }
}

enum SEOAuditStage: Equatable, Sendable {
    case idle
    case discovering
    case auditing(current: Int, total: Int, url: String)
    case lighthouse(url: String)
    case saving
}

struct SEOAuditURLInput {
    static func normalize(_ input: String) -> URL? {
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

    static func projectName(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        if host == "localhost", let port = url.port { return "localhost:\(port)" }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
