import Foundation

public struct GitHubHost: Codable, Hashable, Sendable {
    public let scheme: String
    public let name: String
    public let port: Int?

    public init?(scheme: String = "https", name: String, port: Int? = nil) {
        let normalizedScheme = scheme.lowercased()
        let normalizedName = name.lowercased()
        guard ["http", "https"].contains(normalizedScheme), !normalizedName.isEmpty,
            !normalizedName.contains("/"), !normalizedName.contains(where: \.isWhitespace),
            port.map({ (1...65_535).contains($0) }) ?? true
        else { return nil }
        self.scheme = normalizedScheme
        self.name = normalizedName
        self.port = port
    }

    public init?(url: URL) {
        guard let scheme = url.scheme, let name = url.host,
            url.user == nil, url.password == nil
        else { return nil }
        self.init(scheme: scheme, name: name, port: url.port)
    }

    public static let github = GitHubHost(name: "github.com")!
}

public struct GitHubRepositoryPath: Codable, Hashable, Sendable {
    public let owner: String
    public let name: String

    public init?(owner: String, name: String) {
        guard Self.valid(owner), Self.valid(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains(where: \.isWhitespace)
    }
}

public enum GitHubLineSelection: Codable, Hashable, Sendable {
    case single(Int)
    case range(ClosedRange<Int>)

    public init?(fragment: String?) {
        guard let fragment, fragment.hasPrefix("L") else { return nil }
        let values = fragment.dropFirst().components(separatedBy: "-L")
        guard let first = values.first.flatMap({ Int($0) }), first > 0 else { return nil }
        if values.count == 1 {
            self = .single(first)
        } else if values.count == 2, let last = Int(values[1]), last >= first {
            self = .range(first...last)
        } else {
            return nil
        }
    }

    public var fragment: String {
        switch self {
        case let .single(line): "L\(line)"
        case let .range(lines): "L\(lines.lowerBound)-L\(lines.upperBound)"
        }
    }
}

public enum GitHubContentKind: String, Codable, Hashable, Sendable {
    case tree
    case blob
    case raw
    case blame
}

public enum GitHubContentView: String, Codable, Hashable, Sendable {
    case automatic
    case code
}

public struct GitHubQuery: Codable, Hashable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public enum GitHubRouteResource: Codable, Hashable, Sendable {
    case home
    case search(query: String, type: String?)
    case account(String)
    case organization(String)
    case repository(GitHubRepositoryPath)
    case content(
        repository: GitHubRepositoryPath, kind: GitHubContentKind,
        revisionPath: [String], view: GitHubContentView, lines: GitHubLineSelection?)
    case commits(repository: GitHubRepositoryPath, revision: String?, path: [String])
    case commit(repository: GitHubRepositoryPath, oid: String)
    case comparison(repository: GitHubRepositoryPath, expression: String)
    case branches(GitHubRepositoryPath)
    case tags(GitHubRepositoryPath)
    case pullRequests(repository: GitHubRepositoryPath, query: [GitHubQuery])
    case pullRequest(repository: GitHubRepositoryPath, number: Int)
    case issues(repository: GitHubRepositoryPath, query: [GitHubQuery])
    case issue(repository: GitHubRepositoryPath, number: Int)
    case actions(GitHubRepositoryPath)
    case workflowRun(repository: GitHubRepositoryPath, id: Int)
    case organizationProject(organization: String, number: Int)
    case userProject(user: String, number: Int)
    case repositoryProject(repository: GitHubRepositoryPath, number: Int)
    case repositorySettings(repository: GitHubRepositoryPath, section: [String])
    case accountSettings(section: [String])
    case unsupported(path: [String], query: [GitHubQuery], fragment: String?)
}

public enum GitHubSupportLevel: String, Codable, Hashable, Sendable {
    case fullyNative
    case nativeReadOnly
    case opensOnGitHub
    case unavailable
}

public struct GitHubRoute: Codable, Hashable, Sendable {
    public let host: GitHubHost
    public let resource: GitHubRouteResource

    public init(host: GitHubHost, resource: GitHubRouteResource) {
        self.host = host
        self.resource = resource
    }

    public init?(url: URL) {
        guard let host = GitHubHost(url: url),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let rawSegments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        let segments = rawSegments.compactMap { String($0).removingPercentEncoding }
        guard segments.count == rawSegments.count else { return nil }
        let query = (components.queryItems ?? []).map {
            GitHubQuery(name: $0.name, value: $0.value)
        }
        self.host = host
        self.resource = Self.parse(segments, query: query, fragment: components.fragment)
    }

    public var support: GitHubSupportLevel {
        switch resource {
        case .home, .search, .repository, .content, .commits, .commit, .comparison, .branches,
            .tags:
            .fullyNative
        case .account, .organization, .pullRequests, .pullRequest, .issues, .issue, .actions,
            .workflowRun, .organizationProject, .userProject, .repositoryProject:
            .nativeReadOnly
        case .repositorySettings, .accountSettings:
            .opensOnGitHub
        case .unsupported:
            .unavailable
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = host.scheme
        components.host = host.name
        components.port = host.port
        let representation = Self.representation(resource)
        components.path =
            representation.path.isEmpty ? "/" : "/" + representation.path.joined(separator: "/")
        components.queryItems =
            representation.query.isEmpty
            ? nil : representation.query.map { URLQueryItem(name: $0.name, value: $0.value) }
        components.fragment = representation.fragment
        return components.url!
    }

    private static func parse(
        _ path: [String], query: [GitHubQuery], fragment: String?
    ) -> GitHubRouteResource {
        guard !path.isEmpty else { return .home }
        if path.first == "search" {
            return .search(query: value("q", in: query) ?? "", type: value("type", in: query))
        }
        if path.first == "settings" { return .accountSettings(section: Array(path.dropFirst())) }
        if path.count == 2, path[0] == "orgs" { return .organization(path[1]) }
        if path.count == 4, path[0] == "orgs", path[2] == "projects", let number = positive(path[3])
        {
            return .organizationProject(organization: path[1], number: number)
        }
        if path.count == 4, path[0] == "users", path[2] == "projects",
            let number = positive(path[3])
        {
            return .userProject(user: path[1], number: number)
        }
        if path.count == 1 { return .account(path[0]) }
        guard path.count >= 2, let repository = GitHubRepositoryPath(owner: path[0], name: path[1])
        else { return .unsupported(path: path, query: query, fragment: fragment) }
        guard path.count > 2 else { return .repository(repository) }
        let tail = Array(path.dropFirst(3))
        switch path[2] {
        case "tree", "blob", "raw",
            "blame" where !tail.isEmpty:
            let kind = GitHubContentKind(rawValue: path[2])!
            let view: GitHubContentView = value("plain", in: query) == "1" ? .code : .automatic
            return .content(
                repository: repository, kind: kind, revisionPath: tail, view: view,
                lines: GitHubLineSelection(fragment: fragment))
        case "commits":
            return .commits(
                repository: repository, revision: tail.first, path: Array(tail.dropFirst()))
        case "commit" where tail.count == 1:
            return .commit(repository: repository, oid: tail[0])
        case "compare" where tail.count == 1:
            return .comparison(repository: repository, expression: tail[0])
        case "branches" where tail.isEmpty:
            return .branches(repository)
        case "tags" where tail.isEmpty:
            return .tags(repository)
        case "pulls" where tail.isEmpty:
            return .pullRequests(repository: repository, query: query)
        case "pull" where tail.count == 1:
            return positive(tail[0]).map { .pullRequest(repository: repository, number: $0) }
                ?? .unsupported(path: path, query: query, fragment: fragment)
        case "issues" where tail.isEmpty:
            return .issues(repository: repository, query: query)
        case "issues" where tail.count == 1:
            return positive(tail[0]).map { .issue(repository: repository, number: $0) }
                ?? .unsupported(path: path, query: query, fragment: fragment)
        case "actions" where tail.isEmpty:
            return .actions(repository)
        case "actions" where tail.count == 2 && tail[0] == "runs":
            return positive(tail[1]).map { .workflowRun(repository: repository, id: $0) }
                ?? .unsupported(path: path, query: query, fragment: fragment)
        case "projects" where tail.count == 1:
            return positive(tail[0]).map { .repositoryProject(repository: repository, number: $0) }
                ?? .unsupported(path: path, query: query, fragment: fragment)
        case "settings":
            return .repositorySettings(repository: repository, section: tail)
        default:
            return .unsupported(path: path, query: query, fragment: fragment)
        }
    }

    private static func representation(
        _ resource: GitHubRouteResource
    ) -> (path: [String], query: [GitHubQuery], fragment: String?) {
        switch resource {
        case .home: return ([], [], nil)
        case let .search(query, type):
            return (
                ["search"],
                [GitHubQuery(name: "q", value: query)]
                    + (type.map { [GitHubQuery(name: "type", value: $0)] } ?? []), nil
            )
        case let .account(name): return ([name], [], nil)
        case let .organization(name): return (["orgs", name], [], nil)
        case let .repository(repository): return (base(repository), [], nil)
        case let .content(repository, kind, revisionPath, view, lines):
            return (
                base(repository) + [kind.rawValue] + revisionPath,
                view == .code ? [GitHubQuery(name: "plain", value: "1")] : [], lines?.fragment
            )
        case let .commits(repository, revision, path):
            return (base(repository) + ["commits"] + (revision.map { [$0] } ?? []) + path, [], nil)
        case let .commit(repository, oid): return (base(repository) + ["commit", oid], [], nil)
        case let .comparison(repository, expression):
            return (base(repository) + ["compare", expression], [], nil)
        case let .branches(repository): return (base(repository) + ["branches"], [], nil)
        case let .tags(repository): return (base(repository) + ["tags"], [], nil)
        case let .pullRequests(repository, query): return (base(repository) + ["pulls"], query, nil)
        case let .pullRequest(repository, number):
            return (base(repository) + ["pull", String(number)], [], nil)
        case let .issues(repository, query): return (base(repository) + ["issues"], query, nil)
        case let .issue(repository, number):
            return (base(repository) + ["issues", String(number)], [], nil)
        case let .actions(repository): return (base(repository) + ["actions"], [], nil)
        case let .workflowRun(repository, id):
            return (base(repository) + ["actions", "runs", String(id)], [], nil)
        case let .organizationProject(organization, number):
            return (["orgs", organization, "projects", String(number)], [], nil)
        case let .userProject(user, number):
            return (["users", user, "projects", String(number)], [], nil)
        case let .repositoryProject(repository, number):
            return (base(repository) + ["projects", String(number)], [], nil)
        case let .repositorySettings(repository, section):
            return (base(repository) + ["settings"] + section, [], nil)
        case let .accountSettings(section): return (["settings"] + section, [], nil)
        case let .unsupported(path, query, fragment): return (path, query, fragment)
        }
    }

    private static func base(_ repository: GitHubRepositoryPath) -> [String] {
        [repository.owner, repository.name]
    }

    private static func value(_ name: String, in query: [GitHubQuery]) -> String? {
        query.first { $0.name == name }?.value
    }

    private static func positive(_ value: String) -> Int? {
        guard let number = Int(value), number > 0 else { return nil }
        return number
    }
}
