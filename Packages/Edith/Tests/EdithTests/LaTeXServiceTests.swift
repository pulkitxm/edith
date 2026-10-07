import Foundation
import Testing

@testable import EdithKit

@Suite struct LaTeXServiceTests {
    @Test func repositoryPathsRejectTraversalAndWorkflowExpressions() {
        for path in [
            "../main.tex", "/main.tex", "doc/../../main.tex", "doc//main.tex", "doc\\main.tex",
            "${{ secrets.TOKEN }}.tex", "main\n.tex",
        ] {
            #expect(!LaTeXProject.validRepositoryPath(path))
        }
        #expect(LaTeXProject.validRepositoryPath("papers/hello world.tex"))
        #expect(LaTeXProject.validRepository("octocat/paper"))
        #expect(!LaTeXProject.validRepository("https://github.com/octocat/paper"))
    }

    @Test func repositorySourceReadsPinnedCommitWithoutCheckout() async throws {
        let calls = LaTeXCalls()
        let service = LaTeXService { tool, args, input, directory in
            #expect(tool == "gh")
            #expect(input == nil && directory == nil)
            await calls.record(args)
            if args.contains(where: { $0.contains("git/ref") }) {
                return Data(#"{"object":{"sha":"commit-1"}}"#.utf8)
            }
            #expect(args.contains("ref=commit-1"))
            return Data(
                #"{"type":"file","encoding":"base64","content":"SGVsbG8=","sha":"blob-1"}"#.utf8)
        }
        let source = try await service.load(project())
        #expect(source.text == "Hello" && source.revision == "blob-1")
        #expect(source.baseCommit == "commit-1")
        #expect(await calls.values.count == 2)
    }

    @Test func localSaveRefusesOverwritingExternalEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("main.tex")
        try Data("external".utf8).write(to: url)
        let local = LaTeXProject(name: "Paper", location: .disk, sourcePath: url.path)
        #expect(throws: LaTeXError.self) {
            try LaTeXService.live.saveLocal(
                local, text: "new",
                original: LaTeXSource(text: "old", revision: Data("old".utf8).base64EncodedString())
            )
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "external")
    }

    @Test func repositorySubmitUsesPukbotAndResumesExistingPullRequest() async throws {
        let calls = LaTeXCalls()
        var repo = project()
        repo.reviewBranch = "latex/paper"
        let service = LaTeXService { tool, args, input, directory in
            #expect(directory == nil)
            await calls.record([tool] + args)
            if tool == "pukbot" {
                #expect(args == ["apply", "--input", "-", "--json"])
                let data = try #require(input)
                let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(json["operation"] as? String == "commit_create")
                let files = try #require(json["files"] as? [[String: String]])
                #expect(files[0]["content"] == "New source")
                #expect(files[1]["path"]?.hasPrefix(".github/workflows/edith-latex-") == true)
                return Data()
            }
            if args.contains(where: { $0.contains("git/ref") }) {
                return Data(#"{"object":{"sha":"commit-1"}}"#.utf8)
            }
            if args.contains(where: { $0.contains("/pulls") }) {
                return Data(#"[{"number":42}]"#.utf8)
            }
            return Data(
                #"{"type":"file","encoding":"base64","content":"SGVsbG8=","sha":"blob-1"}"#.utf8)
        }
        let number = try await service.submit(
            repo, text: "New source",
            original: LaTeXSource(text: "Hello", revision: "blob-1", baseCommit: "commit-1"))
        #expect(number == 42)
        #expect(await calls.values.contains { $0.first == "pukbot" })
        #expect(await !calls.values.contains { $0.first == "git" })
    }

    @Test func conflictsNeverWriteGitHub() async throws {
        var repo = project()
        repo.reviewBranch = "latex/paper"
        repo.pullRequest = 42
        let service = LaTeXService { tool, args, _, _ in
            #expect(tool == "gh")
            if args.contains(where: { $0.contains("git/ref") }) {
                return Data(#"{"object":{"sha":"commit-1"}}"#.utf8)
            }
            return Data(
                #"{"type":"file","encoding":"base64","content":"SGVsbG8=","sha":"new-blob"}"#.utf8)
        }
        await #expect(throws: LaTeXError.self) {
            try await service.submit(
                repo, text: "My edit",
                original: LaTeXSource(text: "Old", revision: "old-blob", baseCommit: "commit-1"))
        }
    }

    @Test func quinjetReviewUsesRepositoryOnlyAndMergeUsesPukbot() async throws {
        var repo = project()
        repo.pullRequest = 42
        let service = LaTeXService { tool, args, _, directory in
            #expect(directory == nil)
            #expect(args.contains("octocat/paper"))
            if tool == "pukbot" {
                #expect(args.contains("--delete-branch"))
                #expect(args.contains("--auto"))
                #expect(!args.contains("--admin"))
                return Data()
            }
            #expect(tool == "quinjet")
            switch args[1] {
            case "view":
                return Data(
                    #"{"pullRequest":{"number":42,"title":"Paper","state":"OPEN","url":"https://github.com/octocat/paper/pull/42","headOid":"commit-1","mergeable":"MERGEABLE"}}"#
                        .utf8)
            case "checks":
                return Data(
                    #"{"checks":[{"name":"compile","workflow":"LaTeX PDF","status":"passed","link":"https://github.com/octocat/paper/actions/runs/1"}]}"#
                        .utf8)
            default:
                #expect(!args.contains("--json"))
                return Data("+New source".utf8)
            }
        }
        let review = try await service.review(repo)
        #expect(review.diff == "+New source")
        #expect(review.checks.first?.status == "passed")
        try await service.merge(repo, automatically: true)
    }

    @Test func workflowQuotesSourceAndUploadsPDF() {
        var repo = project()
        repo.sourcePath = "papers/author's draft.tex"
        let yaml = LaTeXService.workflow(repo)
        #expect(yaml.contains("TEX_SOURCE: 'papers/author''s draft.tex'"))
        #expect(yaml.contains("--untrusted"))
        #expect(yaml.contains("actions/upload-artifact@v4"))
        #expect(!yaml.contains("pull_request_target"))
    }

    private func project() -> LaTeXProject {
        LaTeXProject(
            name: "Paper", location: .github, sourcePath: "main.tex", repository: "octocat/paper",
            baseBranch: "main")
    }
}

private actor LaTeXCalls {
    var values: [[String]] = []
    func record(_ args: [String]) { values.append(args) }
}
