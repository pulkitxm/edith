import Foundation

public struct GitHubRepositoryEntryKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let directory = GitHubRepositoryEntryKind(rawValue: "dir")
    public static let file = GitHubRepositoryEntryKind(rawValue: "file")
    public static let symlink = GitHubRepositoryEntryKind(rawValue: "symlink")
    public static let submodule = GitHubRepositoryEntryKind(rawValue: "submodule")
}

public struct GitHubRepositoryEntry: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let path: String
    public let kind: GitHubRepositoryEntryKind
    public let size: Int
    public let sha: String
    public let url: URL?

    public init(
        name: String, path: String, kind: GitHubRepositoryEntryKind, size: Int, sha: String,
        url: URL?
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.sha = sha
        self.url = url
    }

    public var id: String { "\(kind.rawValue):\(path)" }
}

public struct GitHubBranchSummary: Codable, Hashable, Identifiable, Sendable {
    public let name: String
    public let sha: String

    public init(name: String, sha: String) {
        self.name = name
        self.sha = sha
    }

    public var id: String { name }
}

public struct GitHubCommitSummary: Codable, Hashable, Identifiable, Sendable {
    public let sha: String
    public let message: String
    public let authorName: String
    public let authorLogin: String?
    public let authoredAt: Date?
    public let url: URL?

    public init(
        sha: String, message: String, authorName: String, authorLogin: String?, authoredAt: Date?,
        url: URL?
    ) {
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorLogin = authorLogin
        self.authoredAt = authoredAt
        self.url = url
    }

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }
    public var subject: String { message.components(separatedBy: .newlines).first ?? message }
}

public struct GitHubRepositoryOverview: Codable, Hashable, Sendable {
    public let repository: GitHubRepositoryPath
    public let description: String?
    public let isPrivate: Bool
    public let isFork: Bool
    public let isArchived: Bool
    public let defaultBranch: String
    public let stars: Int
    public let forks: Int
    public let openIssues: Int
    public let language: String?
    public let license: String?
    public let topics: [String]
    public let updatedAt: Date?
    public let url: URL
    public let branches: [GitHubBranchSummary]
    public let latestCommit: GitHubCommitSummary?
    public let entries: [GitHubRepositoryEntry]

    public init(
        repository: GitHubRepositoryPath, description: String?, isPrivate: Bool, isFork: Bool,
        isArchived: Bool, defaultBranch: String, stars: Int, forks: Int, openIssues: Int,
        language: String?, license: String?, topics: [String], updatedAt: Date?, url: URL,
        branches: [GitHubBranchSummary], latestCommit: GitHubCommitSummary?,
        entries: [GitHubRepositoryEntry]
    ) {
        self.repository = repository
        self.description = description
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.isArchived = isArchived
        self.defaultBranch = defaultBranch
        self.stars = stars
        self.forks = forks
        self.openIssues = openIssues
        self.language = language
        self.license = license
        self.topics = topics
        self.updatedAt = updatedAt
        self.url = url
        self.branches = branches
        self.latestCommit = latestCommit
        self.entries = entries
    }
}

public struct GitHubDirectorySnapshot: Codable, Hashable, Sendable {
    public let repository: GitHubRepositoryPath
    public let revision: String
    public let path: String
    public let entries: [GitHubRepositoryEntry]

    public init(
        repository: GitHubRepositoryPath, revision: String, path: String,
        entries: [GitHubRepositoryEntry]
    ) {
        self.repository = repository
        self.revision = revision
        self.path = path
        self.entries = entries
    }
}

public enum GitHubFilePresentation: String, Codable, Hashable, Sendable {
    case text
    case image
    case pdf
    case audio
    case video
    case binary
    case gitLFS
    case large
}

public struct GitHubFileSnapshot: Codable, Hashable, Sendable {
    public let repository: GitHubRepositoryPath
    public let revision: String
    public let path: String
    public let sha: String
    public let size: Int
    public let text: String?
    public let downloadURL: URL?
    public let presentation: GitHubFilePresentation

    public init(
        repository: GitHubRepositoryPath, revision: String, path: String, sha: String, size: Int,
        text: String?, downloadURL: URL?, presentation: GitHubFilePresentation
    ) {
        self.repository = repository
        self.revision = revision
        self.path = path
        self.sha = sha
        self.size = size
        self.text = text
        self.downloadURL = downloadURL
        self.presentation = presentation
    }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var lines: [String] {
        guard let text else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}

public enum GitHubRepositoryResource: Codable, Hashable, Sendable {
    case repository(GitHubRepositoryOverview)
    case directory(GitHubDirectorySnapshot)
    case file(GitHubFileSnapshot)
}

public enum GitHubRepositoryLoadError: Error, Codable, Equatable, Sendable {
    case cliUnavailable
    case authenticationRequired(String)
    case permissionDenied(String)
    case notFound(String)
    case rateLimited(String)
    case offline(String)
    case unsupportedRoute(String)
    case invalidResponse(String)
    case commandFailed(String)

    public var title: String {
        switch self {
        case .cliUnavailable: "GitHub CLI Required"
        case .authenticationRequired: "GitHub Sign-in Required"
        case .permissionDenied: "Permission Denied"
        case .notFound: "Not Found"
        case .rateLimited: "GitHub Rate Limit Reached"
        case .offline: "Offline"
        case .unsupportedRoute: "Open on GitHub"
        case .invalidResponse: "Invalid GitHub Response"
        case .commandFailed: "Couldn’t Load GitHub"
        }
    }

    public var message: String {
        switch self {
        case .cliUnavailable:
            "Install the GitHub CLI to browse repositories in Edith."
        case let .authenticationRequired(message), let .permissionDenied(message),
            let .notFound(message), let .rateLimited(message), let .offline(message),
            let .unsupportedRoute(message), let .invalidResponse(message),
            let .commandFailed(message):
            message
        }
    }
}
