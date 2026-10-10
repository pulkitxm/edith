import EdithExtensionSupport
import Foundation

public struct CodeStatsProfile: Codable, Equatable, Sendable {
    public var id: Int
    public var login: String
    public var name: String?
    public var avatarURL: String?
    public var publicRepositories: Int
    public var followers: Int

    public init(
        id: Int, login: String, name: String? = nil, avatarURL: String? = nil,
        publicRepositories: Int = 0, followers: Int = 0
    ) {
        self.id = id
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.publicRepositories = publicRepositories
        self.followers = followers
    }

    public var noreplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
}

public struct CodeStatsRemoteRepository: Codable, Equatable, Sendable {
    public var fullName: String
    public var cloneURL: String
    public var isFork: Bool
    public var isArchived: Bool
    public var sizeKilobytes: Int
    public var pushedAt: String?

    public init(
        fullName: String, cloneURL: String, isFork: Bool = false, isArchived: Bool = false,
        sizeKilobytes: Int = 0, pushedAt: String? = nil
    ) {
        self.fullName = fullName
        self.cloneURL = cloneURL
        self.isFork = isFork
        self.isArchived = isArchived
        self.sizeKilobytes = sizeKilobytes
        self.pushedAt = pushedAt
    }
}

public enum CodeStatsGitHubError: Error, Codable, Equatable, Sendable {
    case unavailable
    case signedOut
    case failed(message: String)
}

public protocol CodeStatsGitHubClient: Sendable {
    func profile() async throws -> CodeStatsProfile
    func emails(for profile: CodeStatsProfile) async -> [String]
    func repositories() async throws -> [CodeStatsRemoteRepository]
}

public struct CodeStatsGitHubCLI: CodeStatsGitHubClient {
    public typealias Runner = @Sendable ([String]) async throws -> CLICommandResult

    public static let repositoryQuery =
        "user/repos?per_page=100&affiliation=owner,collaborator,organization_member"

    private let runner: Runner

    public init(runner: @escaping Runner) {
        self.runner = runner
    }

    public init(executable: URL, environment: [String: String]) {
        let environment = environment.merging([
            "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1",
        ]) { _, forced in forced }
        runner = { arguments in
            try await CLICommandRunner.runLocalSeparated(
                CLICommandRequest(
                    executableURL: executable, arguments: arguments, environment: environment,
                    timeout: 300, maximumOutputBytes: 64 * 1_048_576,
                    terminatesProcessGroup: true),
                onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        }
    }

    public static func resolve() -> CodeStatsGitHubCLI? {
        CLIToolEnvironment.executable(named: "gh").map {
            CodeStatsGitHubCLI(executable: $0, environment: CLIToolEnvironment.sanitized())
        }
    }

    private struct WireProfile: Decodable {
        let id: Int
        let login: String
        let name: String?
        let avatarUrl: String?
        let publicRepos: Int?
        let followers: Int?
    }

    private struct WireRepository: Decodable {
        let fullName: String
        let cloneUrl: String
        let fork: Bool?
        let archived: Bool?
        let size: Int?
        let pushedAt: String?
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func api(_ arguments: [String]) async throws -> String {
        let result = try await runner(["api"] + arguments)
        guard result.terminationStatus == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = message.lowercased()
            if lowered.contains("gh auth login") || lowered.contains("401")
                || lowered.contains("not logged")
            {
                throw CodeStatsGitHubError.signedOut
            }
            throw CodeStatsGitHubError.failed(message: message)
        }
        return result.standardOutput
    }

    public func profile() async throws -> CodeStatsProfile {
        let wire = try Self.decoder.decode(
            WireProfile.self, from: Data(try await api(["user"]).utf8))
        return CodeStatsProfile(
            id: wire.id, login: wire.login, name: wire.name, avatarURL: wire.avatarUrl,
            publicRepositories: wire.publicRepos ?? 0, followers: wire.followers ?? 0)
    }

    public func emails(for profile: CodeStatsProfile) async -> [String] {
        let listed =
            (try? await api(["user/emails", "--jq", ".[] | select(.verified) | .email"])) ?? ""
        let emails = listed.split(whereSeparator: \.isNewline).map(String.init)
        return emails.contains(profile.noreplyEmail) ? emails : emails + [profile.noreplyEmail]
    }

    public func repositories() async throws -> [CodeStatsRemoteRepository] {
        let output = try await api([
            "--paginate", Self.repositoryQuery, "--jq",
            ".[] | {full_name, clone_url, fork, archived, size, pushed_at}",
        ])
        return try output.split(whereSeparator: \.isNewline).map { line in
            let wire = try Self.decoder.decode(WireRepository.self, from: Data(line.utf8))
            return CodeStatsRemoteRepository(
                fullName: wire.fullName, cloneURL: wire.cloneUrl, isFork: wire.fork ?? false,
                isArchived: wire.archived ?? false, sizeKilobytes: wire.size ?? 0,
                pushedAt: wire.pushedAt)
        }
    }
}
