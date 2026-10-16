@testable import CodeStatsExtension
import EdithExtensionSupport
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

    @Test func parsesTheProfileEmailsAndRepositoryListing() async throws {
        let requests = CodeStatsLocked([[String]]())
        let client = CodeStatsGitHubCLI { arguments in
            requests.update { $0.append(arguments) }
            switch arguments[1] {
            case "user":
                return output(
                    #"{"id":7,"login":"octocat","name":"Octo","avatar_url":"https://a/b","#
                        + #""public_repos":3,"followers":9}"#)
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
        let profile = try await client.profile()
        #expect(
            profile
                == CodeStatsProfile(
                    id: 7, login: "octocat", name: "Octo", avatarURL: "https://a/b",
                    publicRepositories: 3, followers: 9))
        #expect(await client.emails(for: profile) == ["7+octocat@users.noreply.github.com"])
        let repositories = try await client.repositories()
        #expect(repositories.map(\.fullName) == ["octo/a", "octo/b"])
        #expect(repositories[0].isArchived && repositories[1].isFork)
        #expect(repositories[0].sizeKilobytes == 42)
        #expect(requests.update { $0.last }?.contains(CodeStatsGitHubCLI.repositoryQuery) == true)
        #expect(CodeStatsSettings().includes(repositories[0]))
        #expect(!CodeStatsSettings().includes(repositories[1]))
    }

    @Test func aMissingLoginIsReportedAsSignedOut() async {
        let client = CodeStatsGitHubCLI { _ in
            output("To get started with GitHub CLI, please run:  gh auth login", status: 4)
        }
        await #expect(throws: CodeStatsGitHubError.signedOut) { try await client.profile() }
        let failing = CodeStatsGitHubCLI { _ in output("boom", status: 1) }
        await #expect(throws: CodeStatsGitHubError.failed(message: "boom")) {
            try await failing.repositories()
        }
    }
}
