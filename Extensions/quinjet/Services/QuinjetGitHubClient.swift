import EdithExtensionSupport
import Foundation

enum QuinjetGitHubError: LocalizedError {
    case missingCLI
    case authentication
    case invalidResponse
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingCLI: "Install GitHub CLI to show pull requests and checks."
        case .authentication: "Sign in with gh auth login to connect your GitHub account."
        case .invalidResponse: "GitHub returned an incomplete response. Refresh to try again."
        case .requestFailed:
            "GitHub could not load pull requests. Check the connection and refresh."
        }
    }
}

struct QuinjetGitHubPull: Equatable, Sendable {
    let id: String
    let repository: String
    let url: URL?
    let row: SurfaceDataRow
}

struct QuinjetGitHubSelection: Sendable {
    let metrics: [SurfaceMetric]
    let pulls: [QuinjetGitHubPull]
    let repositories: [String]
    let message: String?
}

struct QuinjetGitHubClient: Sendable {
    typealias Execute = @Sendable ([String]) async throws -> Data
    private let execute: Execute

    init(execute: @escaping Execute) { self.execute = execute }

    static let live = Self { arguments in
        guard let executable = CLIToolEnvironment.executable(named: "gh") else {
            throw QuinjetGitHubError.missingCLI
        }
        let result = try await CLICommandRunner.run(request(arguments, executable: executable)) {
            _ in
        }
        guard result.terminationStatus == 0 else {
            if arguments.contains("user") { throw QuinjetGitHubError.authentication }
            throw QuinjetGitHubError.requestFailed
        }
        return result.standardOutputData
    }

    static func request(_ arguments: [String], executable: URL) -> CLICommandRequest {
        var environment = CLIToolEnvironment.sanitized()
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "cat"
        return CLICommandRequest(
            executableURL: executable, arguments: arguments, environment: environment,
            timeout: 30, maximumOutputBytes: 1 << 20, terminatesProcessGroup: true)
    }

    func selection(for tile: SurfaceTile) async throws -> QuinjetGitHubSelection {
        let user = try await execute(["api", "--hostname", "github.com", "user", "--jq", ".login"])
        let login = String(decoding: user, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !login.isEmpty, login.count <= 39,
            login.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45
            })
        else { throw QuinjetGitHubError.invalidResponse }
        let data = try await execute([
            "api", "--hostname", "github.com", "graphql", "-f", "query=" + Self.query,
            "-f", "authored=is:pr is:open author:" + login + " sort:updated-desc",
            "-f", "review=is:pr is:open review-requested:" + login + " sort:updated-desc",
            "-f", "assigned=is:pr is:open assignee:" + login + " sort:updated-desc",
        ])
        return try Self.project(data, tile: tile)
    }

    static func project(_ data: Data, tile: SurfaceTile) throws -> QuinjetGitHubSelection {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: data),
            response.errors?.isEmpty != false, let results = response.data
        else { throw QuinjetGitHubError.invalidResponse }
        let groups = [
            ("authored", results.authored), ("review", results.review),
            ("assigned", results.assigned),
        ]
        var pulls: [String: Pull] = [:]
        var roles: [String: Set<String>] = [:]
        var limited = false
        for (role, group) in groups where tile.contentKinds?.contains(role) ?? true {
            limited = limited || group.pageInfo.hasNextPage
            for pull in group.nodes.compactMap({ $0 })
            where tile.sourceIDs?.contains(pull.repository.nameWithOwner) ?? true {
                pulls[pull.id] = pull
                roles[pull.id, default: []].insert(role)
            }
        }
        let selected = pulls.values.sorted {
            let lp = roles[$0.id]?.contains("review") == true ? 1 : 0
            let rp = roles[$1.id]?.contains("review") == true ? 1 : 0
            return lp == rp ? $0.updatedAt > $1.updatedAt : lp > rp
        }
        let repositories = Set(
            groups.flatMap { $0.1.nodes.compactMap { $0 } }.map(\.repository.nameWithOwner)
        ).sorted()
        let metrics = [
            SurfaceMetric("pulls", "Open pull requests", "\(selected.count)"),
            SurfaceMetric(
                "review", "Review requests",
                "\(selected.filter { roles[$0.id]?.contains("review") == true }.count)"),
            SurfaceMetric(
                "failed", "Failing checks",
                "\(selected.filter { ["FAILURE", "ERROR"].contains($0.checks ?? "") }.count)"),
            SurfaceMetric(
                "approved", "Approved",
                "\(selected.filter { $0.reviewDecision == "APPROVED" }.count)"),
        ]
        let rows = selected.map { pull in
            let role =
                roles[pull.id]?.contains("review") == true
                ? "Review requested"
                : roles[pull.id]?.contains("authored") == true ? "Authored" : "Assigned"
            let review = pull.reviewDecision.map {
                $0.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
            }
            let check =
                pull.checks.map { "Checks: " + $0.lowercased().capitalized }
                ?? "No checks reported"
            var labels = [role, check]
            if pull.isDraft { labels.append("Draft") }
            if let review { labels.append(review) }
            let url = URL(string: pull.url).flatMap {
                $0.scheme == "https" && $0.host == "github.com" ? $0 : nil
            }
            let repository = pull.repository.nameWithOwner
            return QuinjetGitHubPull(
                id: pull.id, repository: repository, url: url,
                row: SurfaceDataRow(
                    pull.id, sourceID: repository, title: bounded(pull.title, 256),
                    detail: bounded(
                        "\(repository) #\(pull.number) · " + labels.joined(separator: " · "), 256),
                    value: role, icon: pull.isDraft ? "doc.badge.clock" : "arrow.triangle.pull",
                    actions: url == nil
                        ? [] : [.init("open/" + pull.id, "Open pull request", "arrow.up.right")]))
        }
        return QuinjetGitHubSelection(
            metrics: metrics, pulls: rows, repositories: repositories,
            message: limited
                ? "Showing the 50 most recently updated pull requests per category. Counts cover the loaded selection."
                : selected.isEmpty ? "No open pull requests in this selection." : nil)
    }

    private static func bounded(_ text: String, _ limit: Int) -> String {
        var result = ""
        var count = 0
        for character in text where character != "\0" {
            let size = String(character).utf8.count
            guard count + size <= limit else { break }
            result.append(character)
            count += size
        }
        return result
    }

    static let query = """
        query($authored: String!, $review: String!, $assigned: String!) {
          authored: search(query: $authored, type: ISSUE, first: 50) { ...Pulls }
          review: search(query: $review, type: ISSUE, first: 50) { ...Pulls }
          assigned: search(query: $assigned, type: ISSUE, first: 50) { ...Pulls }
        }
        fragment Pulls on SearchResultItemConnection {
          pageInfo { hasNextPage }
          nodes { ... on PullRequest {
            id url title number isDraft updatedAt reviewDecision repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          } }
        }
        """

    struct Response: Decodable {
        let data: Results?
        let errors: [GraphError]?
    }
    struct GraphError: Decodable { let message: String }
    struct Results: Decodable { let authored: Search; let review: Search; let assigned: Search }
    struct Search: Decodable { let nodes: [Pull?]; let pageInfo: PageInfo }
    struct PageInfo: Decodable { let hasNextPage: Bool }
    struct Pull: Decodable {
        let id: String
        let url: String
        let title: String
        let number: Int
        let isDraft: Bool
        let updatedAt: Date
        let reviewDecision: String?
        let repository: Repository
        let commits: Commits
        var checks: String? { commits.nodes.first?.commit.statusCheckRollup?.state }
    }
    struct Repository: Decodable { let nameWithOwner: String }
    struct Commits: Decodable { let nodes: [CommitNode] }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commit: Decodable { let statusCheckRollup: Check? }
    struct Check: Decodable { let state: String }
}
