@testable import EdithKit
import Foundation
import Testing

@Suite struct CodeStatsGitHubCLITests {
    private func output(_ text: String, status: Int32 = 0) -> CLICommandResult {
        status == 0
            ? CLICommandResult(terminationStatus: 0, output: text)
            : CLICommandResult(
                terminationStatus: status, standardOutputData: Data(),
                standardErrorData: Data(text.utf8))
    }

    private static let accounts =
        #"{"hosts":{"github.com":["#
        + #"{"state":"success","active":false,"host":"github.com","login":"worker"},"#
        + #"{"state":"error","active":false,"host":"github.com","login":"expired"},"#
        + #"{"state":"success","active":true,"host":"github.com","login":"octocat"}]}}"#

    @Test func readsEverySignedInAccountWithItsOwnToken() async throws {
        let requests = CodeStatsLocked([(arguments: [String], token: String?)]())
        let client = CodeStatsGitHubCLI { arguments, environment in
            requests.update { $0.append((arguments, environment["GH_TOKEN"])) }
            if arguments.starts(with: ["auth", "status"]) { return output(Self.accounts) }
            if arguments.starts(with: ["auth", "token"]) {
                return output("token-" + (arguments.last ?? "") + "\n")
            }
            let login = environment["GH_TOKEN"].map { String($0.dropFirst("token-".count)) }
            switch arguments[1] {
            case "user":
                return output(
                    login == "octocat"
                        ? #"{"id":7,"login":"octocat","name":"Octo","avatar_url":"https://a/b","#
                            + #""public_repos":3,"followers":9}"#
                        : #"{"id":8,"login":"worker"}"#)
            case "user/emails":
                return output("HTTP 403: needs the user scope", status: 1)
            default:
                return output(
                    #"{"full_name":"octo/a","clone_url":"https://github.com/octo/a.git","#
                        + #""fork":false,"archived":true,"size":42,"pushed_at":"2026-01-01T00:00:00Z"}"#
                        + "\n"
                        + #"{"full_name":"octo/b","clone_url":"https://github.com/octo/b.git","#
                        + #""fork":true,"archived":false,"size":1,"pushed_at":null}"#)
            }
        }
        let profiles = try await client.profiles()
        #expect(
            profiles == [
                CodeStatsProfile(
                    id: 7, login: "octocat", name: "Octo", avatarURL: "https://a/b",
                    publicRepositories: 3, followers: 9),
                CodeStatsProfile(id: 8, login: "worker"),
            ])
        #expect(
            requests.update { $0 }.filter { $0.arguments == ["api", "user"] }.map(\.token) == [
                "token-octocat", "token-worker",
            ])
        #expect(await client.emails(for: profiles[1]) == ["8+worker@users.noreply.github.com"])
        #expect(await client.token(for: profiles[1]) == "token-worker")
        let repositories = try await client.repositories(for: profiles[1])
        #expect(repositories.map(\.fullName) == ["octo/a", "octo/b"])
        #expect(repositories[0].isArchived && repositories[1].isFork)
        #expect(repositories[0].sizeKilobytes == 42)
        let listing = requests.update { $0.last }
        #expect(listing?.arguments.contains(CodeStatsGitHubCLI.repositoryQuery) == true)
        #expect(listing?.token == "token-worker")
        #expect(CodeStatsSettings().includes(repositories[0]))
        #expect(!CodeStatsSettings().includes(repositories[1]))
    }

    @Test func noSignedInAccountIsReportedAsSignedOut() async {
        let empty = CodeStatsGitHubCLI { _, _ in output(#"{"hosts":{}}"#) }
        await #expect(throws: CodeStatsGitHubError.signedOut) { try await empty.profiles() }
        let missing = CodeStatsGitHubCLI { _, _ in
            output("To get started with GitHub CLI, please run:  gh auth login", status: 4)
        }
        await #expect(throws: CodeStatsGitHubError.signedOut) { try await missing.profiles() }
        let failing = CodeStatsGitHubCLI { arguments, _ in
            arguments.starts(with: ["auth", "token"])
                ? output("token") : output("boom", status: 1)
        }
        await #expect(throws: CodeStatsGitHubError.failed(message: "boom")) {
            try await failing.repositories(for: CodeStatsProfile(id: 1, login: "octocat"))
        }
    }
}
