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
    func profiles() async throws -> [CodeStatsProfile]
    func emails(for profile: CodeStatsProfile) async -> [String]
    func repositories(for profile: CodeStatsProfile) async throws -> [CodeStatsRemoteRepository]
    func token(for profile: CodeStatsProfile) async -> String?
}

public struct CodeStatsGitHubCLI: CodeStatsGitHubClient {
    public typealias Runner =
        @Sendable ([String], [String: String]) async throws -> CLICommandResult

    public static let host = "github.com"
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
        runner = { arguments, extra in
            try await CLICommandRunner.runLocalSeparated(
                CLICommandRequest(
                    executableURL: executable, arguments: arguments,
                    environment: environment.merging(extra) { _, forced in forced },
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

    private struct WireStatus: Decodable {
        struct Account: Decodable {
            let state: String
            let active: Bool
            let login: String
        }
        let hosts: [String: [Account]]
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

    private static func failure(_ result: CLICommandResult) -> CodeStatsGitHubError {
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("gh auth login") || lowered.contains("401")
            || lowered.contains("not logged")
        {
            return .signedOut
        }
        return .failed(message: message)
    }

    private func gh(_ arguments: [String], login: String? = nil) async throws -> String {
        var extra: [String: String] = [:]
        if let login {
            guard let token = await token(login: login) else {
                throw CodeStatsGitHubError.signedOut
            }
            extra["GH_TOKEN"] = token
        }
        let result = try await runner(arguments, extra)
        guard result.terminationStatus == 0 else { throw Self.failure(result) }
        return result.standardOutput
    }

    private func token(login: String) async -> String? {
        let result = try? await runner(
            ["auth", "token", "--hostname", Self.host, "--user", login], [:])
        guard let result, result.terminationStatus == 0 else { return nil }
        let token = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func logins() async throws -> [String] {
        let output = try await gh(["auth", "status", "--hostname", Self.host, "--json", "hosts"])
        let status = try JSONDecoder().decode(WireStatus.self, from: Data(output.utf8))
        let accounts = (status.hosts[Self.host] ?? []).filter { $0.state == "success" }
        guard !accounts.isEmpty else { throw CodeStatsGitHubError.signedOut }
        return accounts.filter(\.active).map(\.login) + accounts.filter { !$0.active }.map(\.login)
    }

    public func profiles() async throws -> [CodeStatsProfile] {
        var profiles: [CodeStatsProfile] = []
        for login in try await logins() {
            let wire = try Self.decoder.decode(
                WireProfile.self, from: Data(try await gh(["api", "user"], login: login).utf8))
            profiles.append(
                CodeStatsProfile(
                    id: wire.id, login: wire.login, name: wire.name, avatarURL: wire.avatarUrl,
                    publicRepositories: wire.publicRepos ?? 0, followers: wire.followers ?? 0))
        }
        return profiles
    }

    public func emails(for profile: CodeStatsProfile) async -> [String] {
        let listed =
            (try? await gh(
                ["api", "user/emails", "--jq", ".[] | select(.verified) | .email"],
                login: profile.login)) ?? ""
        let emails = listed.split(whereSeparator: \.isNewline).map(String.init)
        return emails.contains(profile.noreplyEmail) ? emails : emails + [profile.noreplyEmail]
    }

    public func repositories(for profile: CodeStatsProfile) async throws
        -> [CodeStatsRemoteRepository]
    {
        let output = try await gh(
            [
                "api", "--paginate", Self.repositoryQuery, "--jq",
                ".[] | {full_name, clone_url, fork, archived, size, pushed_at}",
            ], login: profile.login)
        return try output.split(whereSeparator: \.isNewline).map { line in
            let wire = try Self.decoder.decode(WireRepository.self, from: Data(line.utf8))
            return CodeStatsRemoteRepository(
                fullName: wire.fullName, cloneURL: wire.cloneUrl, isFork: wire.fork ?? false,
                isArchived: wire.archived ?? false, sizeKilobytes: wire.size ?? 0,
                pushedAt: wire.pushedAt)
        }
    }

    public func token(for profile: CodeStatsProfile) async -> String? {
        await token(login: profile.login)
    }
}
